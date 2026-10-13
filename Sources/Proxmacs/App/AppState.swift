import AppKit
import Foundation
import Observation

struct VMItem: Identifiable, Hashable {
    var meta: VMMeta
    /// Tart state ("running", "stopped", "suspended") or "missing" if Tart doesn't know the VM.
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
        if tart == nil {
            tart = Tart.locate()
            tartVersion = await tart?.version()
        }
        guard let tart else { vms = []; return }

        let states = Dictionary(((try? await tart.list()) ?? []).map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a })
        vms = VMMeta.allNames().compactMap(VMMeta.load).map { meta in
            let state = states[meta.name] ?? "missing"
            var item = VMItem(meta: meta, state: state, ip: state == "running" ? ips[meta.name] : nil)
            Self.readTartConfig(into: &item)
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
        return tart
    }

    private func item(_ vm: String) -> VMItem? { vms.first { $0.name == vm } }

    // MARK: - VM lifecycle

    func validateNewVM(_ name: String) throws {
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw ProxmacsError("Name must be lowercase letters, digits and dashes")
        }
        if VMMeta.load(name) != nil || FileManager.default.fileExists(atPath: Paths.tartVMDir(name).path) {
            throw ProxmacsError("A VM named \(name) already exists")
        }
    }

    func create(_ request: NewVMRequest, taskID: String? = nil) async throws {
        let name = request.name
        try validateNewVM(name)
        var failure: Error?
        await perform(name, "Create VM", taskID: taskID) { task in
            do {
                try await self.createVM(request, task: task)
                return "Created \(name)"
            } catch {
                failure = error
                throw error
            }
        }
        if let failure { throw failure }
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
            try await tart.set(name, cpu: request.cpus, memoryMB: request.memoryMB, disk: base)
            try await tart.set(name, diskSizeGB: request.diskGB)

            let meta = VMMeta(name: name, network: request.network, autostart: request.autostart)
            try meta.save()
            task.message("Building cloud-init seed…")
            try await CloudInitSeed.build(name: name, password: request.password, agentDeb: agent)
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
        let ok = await perform(vm, "Backup", taskID: taskID) { _ in
            let tart = try requireTart()
            let running = item(vm)?.isRunning ?? false
            let keep = VMMeta.load(vm)?.backup.keep ?? 5
            let info = try await BackupManager.backup(vm, running: running, tart: tart, keep: keep)
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
            if VMMeta.load(vm) == nil || !FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
                try await recreate(vm, from: backup, tart: tart, task: task)
                return "Recreated \(vm) from backup of \(backup.record.date.formatted())"
            }
            if item(vm)?.isRunning == true {
                throw ProxmacsError("Stop the VM before restoring")
            }
            try await BackupManager.restore(vm, from: backup, tart: tart)
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
        try await tart.set(vm, disk: disk)

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
        NSPasteboard.general.setString("ssh debian@\(ip)", forType: .string)
        status = "Copied: ssh debian@\(ip)"
    }
}

