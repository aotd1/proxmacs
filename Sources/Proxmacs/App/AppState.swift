import AppKit
import Foundation
import Observation

struct VMItem: Identifiable, Hashable {
    var meta: VMMeta
    /// Tart state ("running", "stopped", "suspended"), "missing" if Tart doesn't know the VM, or
    /// "offline" while VM storage is unavailable (drive disconnected).
    var state: String
    var ip: String?
    var cpus: Int?
    var memoryMB: Int?
    var diskGB: Int?

    var id: String { meta.name }
    var name: String { meta.name }
    var isRunning: Bool { state == "running" }
}

enum ImageSource: Hashable {
    case debian13
    case local(URL)
}

struct NewVMRequest {
    var name: String
    var cpus: Int
    var memoryMB: Int
    var diskGB: Int
    var network: NetworkMode
    var image: ImageSource
    var password: String
    var autostart: Bool
    var startNow: Bool
    var user = "debian"
    /// nil = the host user's ~/.ssh/*.pub keys.
    var sshKeys: [String]? = nil
    var guestNetwork = GuestNetwork()

    var cloudInit: CloudInitConfig {
        CloudInitConfig(user: user, sshKeys: sshKeys ?? CloudInitSeed.sshPublicKeys(), network: guestNetwork)
    }
}

/// Hardware edits; nil fields stay unchanged. Applied with `tart set`, so the VM must be stopped.
struct HardwareChange {
    var cpus: Int?
    var memoryMB: Int?
    var diskGB: Int?
    var network: NetworkMode?
}

enum PasswordChange: Equatable {
    case keep
    case set(String)
    case remove
}

struct ProxmacsError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Proxmox-style task log entry: every long-running action is recorded here.
struct TaskRecord: Identifiable, Hashable, Codable {
    enum Status: String, Codable { case running, ok, error }

    var id: String
    var vm: String?
    var title: String
    var status: Status = .running
    var message: String?
    var progress: Double?
    var started = Date()
    var finished: Date?
}

@MainActor
@Observable
final class AppState {
    private(set) var tart: Tart?
    private(set) var tartVersion: String?
    private(set) var vms: [VMItem] = []
    /// VM name → what is currently happening to it.
    private(set) var activity: [String: String] = [:]
    /// Newest first, capped.
    private(set) var tasks: [TaskRecord] = []
    private(set) var memory: HostMemory?
    private(set) var vmStorageOnline = true
    private(set) var backupStorageOnline = true
    /// Set while VM storage or backups are being moved; other actions wait.
    private(set) var storageBusy: StorageKind?
    var status: String? {
        didSet { if let status { onStatus?(status) } }
    }
    var lastError: String?
    /// Lets the CLI echo progress messages.
    var onStatus: ((String) -> Void)?

    private var ips: [String: String] = [:]
    private var lastScheduledBackup: [String: Date] = [:]

    init(autoRefresh: Bool = true) {
        Paths.ensure()
        if autoRefresh {
            Task { await loop() }
        }
    }

    private func loop() async {
        while true {
            await refresh()
            await runScheduledBackups()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refresh() async {
        memory = HostStats.memory()
        if tart == nil {
            tart = Tart.locate()
            tartVersion = await tart?.version()
        }
        vmStorageOnline = Storage.isAvailable(.vms)
        backupStorageOnline = Storage.isAvailable(.backups)
        guard let tart else { vms = []; return }

        let online = vmStorageOnline && storageBusy != .vms
        let states = online ? Dictionary(((try? await tart.list()) ?? []).map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a }) : [:]
        vms = VMMeta.allNames().compactMap(VMMeta.load).map { meta in
            let state = online ? states[meta.name] ?? "missing" : "offline"
            var item = VMItem(meta: meta, state: state, ip: state == "running" ? ips[meta.name] : nil)
            if online { Self.readTartConfig(into: &item) }
            return item
        }

        for item in vms where item.isRunning {
            let ip = await resolveIP(item, tart: tart)
            ips[item.name] = ip
            if let index = vms.firstIndex(where: { $0.name == item.name }) { vms[index].ip = ip }
        }
    }

    private static func readTartConfig(into item: inout VMItem) {
        let dir = Paths.tartVMDir(item.name)
        if let data = try? Data(contentsOf: dir.appending(path: "config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            item.cpus = (config["cpuCount"] as? NSNumber)?.intValue
            item.memoryMB = (config["memorySize"] as? NSNumber).map { Int($0.int64Value / 1024 / 1024) }
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: "disk.img").path))?[.size] as? NSNumber {
            item.diskGB = Int(size.int64Value / 1_000_000_000)
        }
    }

    private func resolveIP(_ item: VMItem, tart: Tart) async -> String? {
        // The guest agent knows the truth in every mode; until it's installed (first boot), fall back
        // to DHCP leases (NAT) or the host ARP table (bridged).
        if let ip = await tart.ip(item.name, resolver: .agent) { return ip }
        switch item.meta.network {
        case .nat: return await tart.ip(item.name, resolver: .dhcp)
        case .bridged: return await tart.ip(item.name, resolver: .arp)
        }
    }

    // MARK: - Tasks

    /// Handle passed to task bodies for progress/message updates (callable from any thread).
    struct TaskHandle: Sendable {
        let id: String
        let update: @Sendable (Double?, String?) -> Void

        func progress(_ fraction: Double) { update(fraction, nil) }
        func message(_ text: String) { update(nil, text) }
    }

    /// Like `perform`, but rethrows the task's error to the caller.
    func performThrowing(_ vm: String?, _ title: String, taskID: String? = nil, _ work: (TaskHandle) async throws -> String?) async throws {
        var failure: Error?
        await perform(vm, title, taskID: taskID) { task in
            do {
                return try await work(task)
            } catch {
                failure = error
                throw error
            }
        }
        if let failure { throw failure }
    }

    /// Runs `work` as a recorded task. Returns false (and records the error) on failure.
    @discardableResult
    func perform(_ vm: String?, _ title: String, taskID: String? = nil, _ work: (TaskHandle) async throws -> String?) async -> Bool {
        let id = taskID ?? UUID().uuidString.lowercased()
        tasks.insert(TaskRecord(id: id, vm: vm, title: title), at: 0)
        if tasks.count > 200 { tasks.removeLast(tasks.count - 200) }
        if let vm { activity[vm] = title }

        let handle = TaskHandle(id: id) { [weak self] progress, message in
            Task { @MainActor in self?.updateTask(id, progress: progress, message: message) }
        }
        var succeeded = true
        do {
            let message = try await work(handle)
            finishTask(id, status: .ok, message: message)
            if let message { status = message }
        } catch {
            succeeded = false
            finishTask(id, status: .error, message: error.localizedDescription)
            lastError = "\(vm.map { "\($0): " } ?? "")\(error.localizedDescription)"
        }
        if let vm { activity[vm] = nil }
        await refresh()
        return succeeded
    }

    private func updateTask(_ id: String, progress: Double?, message: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .running else { return }
        if let progress { tasks[index].progress = progress }
        if let message {
            tasks[index].message = message
            status = message
        }
    }

    private func finishTask(_ id: String, status: TaskRecord.Status, message: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        tasks[index].finished = Date()
        if status == .ok { tasks[index].progress = 1 }
        if let message { tasks[index].message = message }
    }

    private func requireTart() throws -> Tart {
        guard let tart else { throw ProxmacsError("Tart is not installed (brew install openai/tools/tart)") }
        if let busy = storageBusy { throw ProxmacsError("\(busy.label) is being moved; try again when that has finished") }
        try Storage.require(.vms)
        return tart
    }

    private func item(_ vm: String) -> VMItem? { vms.first { $0.name == vm } }

    // MARK: - VM lifecycle

    func validateNewVM(_ name: String) throws {
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw ProxmacsError("Name must be lowercase letters, digits and dashes")
        }
        try Storage.require(.vms)
        if VMMeta.load(name) != nil || FileManager.default.fileExists(atPath: Paths.tartVMDir(name).path) {
            throw ProxmacsError("A VM named \(name) already exists")
        }
    }

    func create(_ request: NewVMRequest, taskID: String? = nil) async throws {
        let name = request.name
        try validateNewVM(name)
        try request.cloudInit.validate()
        try await performThrowing(name, "Create VM", taskID: taskID) { task in
            try await self.createVM(request, task: task)
            return "Created \(name)"
        }
    }

    private func createVM(_ request: NewVMRequest, task: TaskHandle) async throws {
        let tart = try requireTart()
        let name = request.name
        let report: @Sendable (String) -> Void = { task.message($0) }

        let base: URL = switch request.image {
        case .debian13: try await ImageStore.debianBase(status: report)
        case .local(let url): try await ImageStore.importLocal(url, status: report)
        }
        let agent = try await ImageStore.agentPackage(status: report)

        task.message("Creating VM \(name)…")
        try await tart.createLinux(name, diskSizeGB: request.diskGB)
        do {
            try await tart.set(name, cpu: request.cpus, memoryMB: request.memoryMB)
            task.message("Copying base image…")
            try await BackupManager.setDisk(name, from: base, tart: tart) { task.progress($0) }
            try await tart.set(name, diskSizeGB: request.diskGB)

            var config = request.cloudInit
            if !request.password.isEmpty {
                let password = request.password
                config.passwordHash = await Task.detached { SHA512Crypt.hash(password) }.value
            }
            var meta = VMMeta(name: name, network: request.network, autostart: request.autostart)
            meta.cloudInit = config
            try meta.save()
            task.message("Building cloud-init seed…")
            try await CloudInitSeed.build(name: name, config: config, agentDeb: agent)
            try LaunchAgent.write(tart: tart, meta: meta)
        } catch {
            // Roll back so a half-created VM doesn't linger.
            try? await tart.delete(name)
            try? FileManager.default.removeItem(at: Paths.vmDir(name))
            try? FileManager.default.removeItem(at: LaunchAgent.plistURL(name))
            throw error
        }

        if request.startNow {
            task.message("Starting \(name)…")
            try await LaunchAgent.start(name)
        }
    }

    func start(_ vm: String, taskID: String? = nil) async {
        await perform(vm, "Start", taskID: taskID) { _ in
            let tart = try requireTart()
            guard let meta = VMMeta.load(vm) else { throw ProxmacsError("missing metadata") }
            try LaunchAgent.write(tart: tart, meta: meta)  // pick up any metadata changes
            try await LaunchAgent.start(vm)
            return nil
        }
    }

    func stop(_ vm: String, taskID: String? = nil) async {
        await perform(vm, "Shutdown", taskID: taskID) { _ in
            try await requireTart().stop(vm)
            return nil
        }
    }

    func delete(_ vm: String, taskID: String? = nil) async {
        await perform(vm, "Delete", taskID: taskID) { _ in
            let tart = try requireTart()
            if item(vm)?.isRunning == true {
                try? await tart.stop(vm, timeout: 10)
            }
            await LaunchAgent.remove(vm)
            if FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
                try await tart.delete(vm)
            }
            try FileManager.default.removeItem(at: Paths.vmDir(vm))
            ips[vm] = nil
            return "Deleted \(vm); backups kept"
        }
    }

    // MARK: - Editing

    func editHardware(_ vm: String, _ change: HardwareChange, taskID: String? = nil) async throws {
        guard let current = item(vm), let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        let networkChanged = change.network.map { $0 != meta.network } ?? false
        let cpus = change.cpus.flatMap { $0 == current.cpus ? nil : $0 }
        let memoryMB = change.memoryMB.flatMap { $0 == current.memoryMB ? nil : $0 }
        let diskGB = change.diskGB.flatMap { $0 == current.diskGB ? nil : $0 }
        guard cpus != nil || memoryMB != nil || diskGB != nil || networkChanged else { return }

        guard current.state == "stopped" else { throw ProxmacsError("Shut down \(vm) before changing its hardware") }
        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        if let cpus, !(1...hostCPUs).contains(cpus) { throw ProxmacsError("CPUs must be between 1 and \(hostCPUs)") }
        let hostMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
        if let memoryMB, !(512...hostMB).contains(memoryMB) { throw ProxmacsError("Memory must be between 512 MB and \(hostMB) MB") }
        if let diskGB, let size = current.diskGB, diskGB < size {
            throw ProxmacsError("Disks can only grow (\(vm) has \(size) GB)")
        }
        if let diskGB, diskGB > 16_384 { throw ProxmacsError("Disk size too large") }

        try await performThrowing(vm, "Edit hardware", taskID: taskID) { _ in
            let tart = try requireTart()
            if cpus != nil || memoryMB != nil || diskGB != nil {
                try await tart.set(vm, cpu: cpus, memoryMB: memoryMB, diskSizeGB: diskGB)
            }
            if networkChanged, let network = change.network {
                try updateMeta(vm) { $0.network = network }
            }
            var changes: [String] = []
            if let cpus { changes.append("\(cpus) CPUs") }
            if let memoryMB { changes.append("\(memoryMB) MB memory") }
            if let diskGB { changes.append("\(diskGB) GB disk (the root filesystem grows on next boot)") }
            if networkChanged, let network = change.network { changes.append(network.label) }
            return "\(vm): " + changes.joined(separator: ", ")
        }
    }

    /// Stores new cloud-init settings and rebuilds the seed; cloud-init applies them on the next start.
    func editCloudInit(_ vm: String, user: String, password: PasswordChange, sshKeys: [String], network: GuestNetwork,
                       taskID: String? = nil) async throws {
        guard let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        var config = meta.effectiveCloudInit
        config.user = user
        config.sshKeys = sshKeys
        config.network = network
        switch password {
        case .keep:
            break
        case .set(let plain):
            guard !plain.isEmpty else { throw ProxmacsError("Password is empty") }
            config.passwordHash = await Task.detached { SHA512Crypt.hash(plain) }.value
            config.managePassword = true
        case .remove:
            config.passwordHash = nil
            config.managePassword = true
        }
        try config.validate()

        try await performThrowing(vm, "Edit cloud-init", taskID: taskID) { task in
            let agent = try await ImageStore.agentPackage { task.message($0) }
            try await CloudInitSeed.build(name: vm, config: config, agentDeb: agent)
            let running = item(vm)?.isRunning ?? false
            try updateMeta(vm) {
                $0.cloudInit = config
                $0.seedPending = running
            }
            return running ? "Cloud-init updated: shut down and start \(vm) to apply" : "Cloud-init updated: applied when \(vm) next starts"
        }
    }

    func updateMeta(_ vm: String, _ change: (inout VMMeta) -> Void) throws {
        guard var meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        change(&meta)
        try meta.save()
        if let tart { try LaunchAgent.write(tart: tart, meta: meta) }
        if let index = vms.firstIndex(where: { $0.name == vm }) { vms[index].meta = meta }
    }

    func setAutostart(_ vm: String, _ enabled: Bool) async {
        do { try updateMeta(vm) { $0.autostart = enabled } } catch { lastError = error.localizedDescription }
    }

    func setBackupPolicy(_ vm: String, _ policy: BackupPolicy) {
        do { try updateMeta(vm) { $0.backup = policy } } catch { lastError = error.localizedDescription }
    }

    // MARK: - Local backups

    func backup(_ vm: String, taskID: String? = nil) async {
        let ok = await perform(vm, "Backup", taskID: taskID) { task in
            let tart = try requireTart()
            if storageBusy == .backups { throw ProxmacsError("Backups are being moved; try again when that has finished") }
            let running = item(vm)?.isRunning ?? false
            let keep = VMMeta.load(vm)?.backup.keep ?? 5
            let info = try await BackupManager.backup(vm, running: running, tart: tart, keep: keep) { task.progress($0) }
            return info.record.consistent ? "Backup of \(vm) done" : "Backup of \(vm) done (crash-consistent: guest agent unreachable)"
        }
        guard ok, let meta = VMMeta.load(vm), meta.offsite.auto, let latest = BackupManager.list(vm).first else { return }
        for target in meta.offsite.targets {
            await push(vm, backup: latest, targetID: target)
        }
    }

    func restore(_ vm: String, _ backup: BackupInfo, taskID: String? = nil) async {
        await perform(vm, "Restore", taskID: taskID) { task in
            let tart = try requireTart()
            try Storage.require(.backups)
            if VMMeta.load(vm) == nil || !FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
                try await recreate(vm, from: backup, tart: tart, task: task)
                return "Recreated \(vm) from backup of \(backup.record.date.formatted())"
            }
            if item(vm)?.isRunning == true {
                throw ProxmacsError("Stop the VM before restoring")
            }
            try await BackupManager.restore(vm, from: backup, tart: tart) { task.progress($0) }
            return "Restored \(vm) from \(backup.record.date.formatted())"
        }
    }

    /// Disaster recovery: builds a VM that no longer exists from a (possibly pulled) backup.
    private func recreate(_ vm: String, from backup: BackupInfo, tart: Tart, task: TaskHandle) async throws {
        task.message("Recreating \(vm) from backup…")
        let disk = backup.url.appending(path: BackupFiles.disk)
        let size = ((try? FileManager.default.attributesOfItem(atPath: disk.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let diskGB = max(Int((size + 999_999_999) / 1_000_000_000), 1)

        if !FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
            try await tart.createLinux(vm, diskSizeGB: diskGB)
        }
        let tartDir = Paths.tartVMDir(vm)
        // Tart's config carries the MAC address: keeping it preserves DHCP reservations on the LAN.
        for file in ["config.json", "nvram.bin"] {
            let source = backup.url.appending(path: file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.removeItem(at: tartDir.appending(path: file))
            try FileManager.default.copyItem(at: source, to: tartDir.appending(path: file))
        }
        try await BackupManager.setDisk(vm, from: disk, tart: tart) { task.progress($0) }

        var meta = (try? JSONDecoder.proxmacs.decode(VMMeta.self, from: Data(contentsOf: backup.url.appending(path: "meta.json"))))
            ?? VMMeta(name: vm, network: .nat, autostart: false)
        meta.name = vm
        meta.autostart = false
        try meta.save()
        try LaunchAgent.write(tart: tart, meta: meta)
    }

    func deleteBackup(_ backup: BackupInfo) throws {
        try BackupManager.delete(backup)
    }

    private func runScheduledBackups() async {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        for item in vms where item.meta.backup.daily && item.meta.backup.hour == hour && activity[item.name] == nil {
            let last = lastScheduledBackup[item.name] ?? BackupManager.list(item.name).first?.record.date
            if let last, Calendar.current.isDate(last, inSameDayAs: now) { continue }
            lastScheduledBackup[item.name] = now
            await backup(item.name)
        }
    }

    // MARK: - Offsite

    var targets: [OffsiteTarget] { TargetStore.load() }

    func push(_ vm: String, backup: BackupInfo, targetID: String, taskID: String? = nil) async {
        guard let target = TargetStore.target(targetID) else {
            lastError = "Unknown offsite target \(targetID)"
            return
        }
        await perform(vm, "Push to \(target.name)", taskID: taskID) { task in
            try Storage.require(.backups)
            let backend = try target.backend()
            task.message("Uploading \(vm) to \(target.name)…")
            try await backend.push(vm: vm, backupDir: backup.url, record: backup.record) { task.progress($0) }
            do {
                try await backend.prune(vm: vm, keep: target.keep)
            } catch {
                return "Pushed \(vm) to \(target.name) (prune failed: \(error.localizedDescription))"
            }
            return "Pushed \(vm) to \(target.name)"
        }
    }

    func remoteSnapshots(targetID: String, vm: String) async throws -> [RemoteSnapshot] {
        guard let target = TargetStore.target(targetID) else { throw ProxmacsError("Unknown offsite target \(targetID)") }
        return try await target.backend().snapshots(vm: vm)
    }

    /// Copies a remote snapshot into the local backups of `vm`; recreates the VM if it doesn't exist.
    func pull(_ vm: String, snapshotID: String, targetID: String, taskID: String? = nil) async {
        guard let target = TargetStore.target(targetID) else {
            lastError = "Unknown offsite target \(targetID)"
            return
        }
        var pulled: BackupInfo?
        let ok = await perform(vm, "Pull from \(target.name)", taskID: taskID) { task in
            try Storage.require(.backups)
            if storageBusy == .backups { throw ProxmacsError("Backups are being moved; try again when that has finished") }
            let backend = try target.backend()
            let snapshots = try await backend.snapshots(vm: vm)
            guard let snapshot = snapshots.first(where: { $0.id == snapshotID }) else {
                throw ProxmacsError("Snapshot \(snapshotID) of \(vm) not found on \(target.name)")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            let dir = Paths.backupsDir(vm).appending(path: "\(formatter.string(from: snapshot.time))-\(target.name)", directoryHint: .isDirectory)
            let partial = dir.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partial)
            task.message("Downloading \(vm) from \(target.name)…")
            try await backend.pull(snapshot, into: partial) { task.progress($0) }
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.moveItem(at: partial, to: dir)
            pulled = BackupManager.list(vm).first { $0.url.lastPathComponent == dir.lastPathComponent }
            return "Pulled \(vm) snapshot into local backups"
        }
        if ok, let pulled, VMMeta.load(vm) == nil {
            await restore(vm, pulled)
        }
    }

    func addTarget(_ target: OffsiteTarget, secret: String?) throws {
        try TargetStore.add(target, secret: secret)
    }

    func removeTarget(_ id: String) throws {
        try TargetStore.remove(id)
        for vm in VMMeta.allNames() {
            try? updateMeta(vm) { $0.offsite.targets.removeAll { $0 == id } }
        }
    }

    func testTarget(_ id: String) async -> (ok: Bool, message: String) {
        guard let target = TargetStore.target(id) else { return (false, "Unknown target") }
        do {
            return (true, try await target.backend().test())
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Storage

    struct StoragePlan {
        var kind: StorageKind
        var old: URL
        var new: URL
        var custom: Bool
        var moves: [(from: URL, to: URL)]
        var crossVolume: Bool
        var oldAvailable: Bool
        /// Backups already present at the new location (left where they are).
        var skipped: Int
    }

    /// Checks a move of VM storage or local backups to `path` (nil = back to the default on the
    /// internal disk). Data reachable at the old location moves along; a new location that already
    /// holds Proxmacs data of the same kind (a reconnected drive) is adopted as is.
    func planStorageChange(_ kind: StorageKind, to path: String?) async throws -> StoragePlan {
        if kind == .vms && Storage.tartHomeOverridden { throw ProxmacsError("VM storage is set by the TART_HOME environment variable") }
        if let busy = storageBusy { throw ProxmacsError("\(busy.label) is already being moved") }
        let old = Storage.canonical(Storage.url(kind))
        let requested = path.map(Storage.canonical(path:)) ?? Storage.canonical(kind == .vms ? Paths.defaultTartHome : Paths.defaultBackups)
        guard requested.path != old.path else { throw ProxmacsError("\(kind.label) is already at \(old.path)") }
        let new = try path.map { try Storage.validate($0, for: kind) } ?? requested

        await refresh()
        guard activity.isEmpty else { throw ProxmacsError("Wait for running tasks to finish first") }
        if kind == .vms, let running = vms.first(where: \.isRunning) {
            throw ProxmacsError("Shut down all VMs first (\(running.name) is running)")
        }

        let oldAvailable = Storage.isAvailable(kind)
        var moves: [(from: URL, to: URL)] = []
        var skipped = 0
        if oldAvailable {
            let fm = FileManager.default
            switch kind {
            case .vms:
                for name in VMMeta.allNames() {
                    let from = old.appending(path: "vms/\(name)", directoryHint: .isDirectory)
                    let to = new.appending(path: "vms/\(name)", directoryHint: .isDirectory)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    if fm.fileExists(atPath: to.path) {
                        throw ProxmacsError("\(new.path) already holds a VM named \(name); remove one of them first")
                    }
                    moves.append((from, to))
                }
            case .backups:
                let vmDirs = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
                for vm in vmDirs.sorted() where vm.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil {
                    for entry in ((try? fm.contentsOfDirectory(atPath: old.appending(path: vm).path)) ?? []).sorted() {
                        let from = old.appending(path: "\(vm)/\(entry)", directoryHint: .isDirectory)
                        if entry.hasSuffix(".partial") { continue }
                        let to = new.appending(path: "\(vm)/\(entry)", directoryHint: .isDirectory)
                        if fm.fileExists(atPath: to.path) { skipped += 1; continue }
                        moves.append((from, to))
                    }
                }
            }
        }
        let crossVolume = !FileCopy.sameVolume(old, new)
        if crossVolume, !moves.isEmpty, let volume = Storage.volume(containing: new) {
            let needed = moves.reduce(Int64(0)) { $0 + FileCopy.allocatedSize(of: $1.from) }
            if needed > volume.freeBytes {
                throw ProxmacsError("Not enough space on \(volume.name): \(Self.bytes(needed)) needed, \(Self.bytes(volume.freeBytes)) free")
            }
        }
        return StoragePlan(kind: kind, old: old, new: new, custom: path != nil, moves: moves, crossVolume: crossVolume,
                           oldAvailable: oldAvailable, skipped: skipped)
    }

    func changeStorage(_ plan: StoragePlan, taskID: String? = nil) async throws {
        if let busy = storageBusy { throw ProxmacsError("\(busy.label) is already being moved") }
        storageBusy = plan.kind
        do {
            try await moveStorage(plan, taskID: taskID)
        } catch {
            storageBusy = nil
            await refresh()
            throw error
        }
        storageBusy = nil
        await refresh()
    }

    private func moveStorage(_ plan: StoragePlan, taskID: String?) async throws {
        let (kind, old, new, custom, moves) = (plan.kind, plan.old, plan.new, plan.custom, plan.moves)
        let (crossVolume, oldAvailable, skipped) = (plan.crossVolume, plan.oldAvailable, plan.skipped)
        try await performThrowing(nil, "Move \(kind.noun)", taskID: taskID) { task in
            if custom { try Storage.prepare(new, for: kind) } else {
                try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
            }
            task.message("Moving \(moves.count) \(kind == .vms ? "VM" : "backup")\(moves.count == 1 ? "" : "s") to \(new.path)…")
            try await Task.detached(priority: .userInitiated) {
                try Self.transfer(moves, crossVolume: crossVolume, staging: new.appending(path: ".proxmacs-moving", directoryHint: .isDirectory)) {
                    task.progress($0)
                }
            }.value

            var settings = Storage.settings
            settings[kind] = custom ? new.path : nil
            try Storage.save(settings)
            if kind == .vms {
                try? FileManager.default.removeItem(at: old.appending(path: ".proxmacs-staging"))
            }
            var message = "\(kind.label) is now at \(new.path)"
            if !oldAvailable {
                message += "; the old location was not available, so nothing was moved"
            } else if !moves.isEmpty {
                message += " (moved \(moves.count) \(kind == .vms ? "VM" : "backup")\(moves.count == 1 ? "" : "s"))"
            }
            if skipped > 0 { message += "; \(skipped) backup(s) already present there were left at \(old.path)" }
            return message
        }
    }

    /// Copies everything first (sources untouched, so a failure changes nothing), then renames the
    /// copies into place and deletes the sources. Within one volume it just renames.
    private nonisolated static func transfer(_ moves: [(from: URL, to: URL)], crossVolume: Bool, staging: URL,
                                             progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        if !crossVolume {
            for (index, move) in moves.enumerated() {
                try fm.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: move.from, to: move.to)
                progress(Double(index + 1) / Double(moves.count))
            }
            return
        }
        let total = Double(max(moves.reduce(Int64(0)) { $0 + FileCopy.size(of: $1.from) }, 1))
        var done: Int64 = 0
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (index, move) in moves.enumerated() {
            try FileCopy.copyTree(move.from, to: staging.appending(path: String(index))) { bytes in
                done += bytes
                progress(min(Double(done) / total, 0.99))
            }
        }
        for (index, move) in moves.enumerated() {
            try fm.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging.appending(path: String(index)), to: move.to)
        }
        for move in moves {
            try? fm.removeItem(at: move.from)
            // Drop emptied per-VM backup directories.
            let parent = move.from.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true, parent.lastPathComponent != "vms" {
                try? fm.removeItem(at: parent)
            }
        }
        progress(1)
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Host helpers

    func openConsole(_ vm: String) {
        guard FileManager.default.fileExists(atPath: VMRunner.socketPath(vm).path) else {
            lastError = "\(vm): no console (is the VM running?)"
            return
        }
        let script = Paths.vmDir(vm).appending(path: "console.command")
        let body = """
        #!/bin/sh
        printf '\\033]0;%s console\\007' '\(vm)'
        exec '\(LaunchAgent.selfExecutable)' cli console '\(vm)'

        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func copySSHCommand(_ item: VMItem) {
        guard let ip = item.ip else { return }
        NSPasteboard.general.clearContents()
        let command = "ssh \(item.meta.effectiveCloudInit.user)@\(ip)"
        NSPasteboard.general.setString(command, forType: .string)
        status = "Copied: \(command)"
    }
}

