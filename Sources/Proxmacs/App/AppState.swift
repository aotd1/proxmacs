import AppKit
import Foundation
import Observation

struct VMItem: Identifiable, Hashable {
    var meta: VMMeta
    /// Tart state ("running", "stopped", "suspended") or "missing" if Tart doesn't know the VM.
    var state: String
    var ip: String?

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

@MainActor
@Observable
final class AppState {
    private(set) var tart: Tart?
    private(set) var tartVersion: String?
    private(set) var vms: [VMItem] = []
    /// VM name → what is currently happening to it.
    private(set) var activity: [String: String] = [:]
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
            return VMItem(meta: meta, state: state, ip: state == "running" ? ips[meta.name] : nil)
        }

        for item in vms where item.isRunning {
            let ip = await resolveIP(item, tart: tart)
            ips[item.name] = ip
            if let index = vms.firstIndex(where: { $0.name == item.name }) { vms[index].ip = ip }
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

    // MARK: - Actions

    private func perform(_ vm: String, _ label: String, _ work: () async throws -> Void) async {
        activity[vm] = label
        defer { activity[vm] = nil }
        do {
            try await work()
        } catch {
            lastError = "\(vm): \(error.localizedDescription)"
        }
        await refresh()
    }

    private func requireTart() throws -> Tart {
        guard let tart else { throw ProxmacsError("Tart is not installed (brew install openai/tools/tart)") }
        return tart
    }

    func create(_ request: NewVMRequest) async throws {
        let tart = try requireTart()
        let name = request.name
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw ProxmacsError("Name must be lowercase letters, digits and dashes")
        }
        if VMMeta.load(name) != nil || FileManager.default.fileExists(atPath: Paths.tartVMDir(name).path) {
            throw ProxmacsError("A VM named \(name) already exists")
        }

        activity[name] = "Creating…"
        defer { activity[name] = nil; status = nil }
        let report: @Sendable (String) -> Void = { message in Task { @MainActor in self.status = message } }

        let base: URL = switch request.image {
        case .debian13: try await ImageStore.debianBase(status: report)
        case .local(let url): try await ImageStore.importLocal(url, status: report)
        }
        let agent = try await ImageStore.agentPackage(status: report)

        status = "Creating VM \(name)…"
        try await tart.createLinux(name, diskSizeGB: request.diskGB)
        do {
            try await tart.set(name, cpu: request.cpus, memoryMB: request.memoryMB, disk: base)
            try await tart.set(name, diskSizeGB: request.diskGB)

            let meta = VMMeta(name: name, network: request.network, autostart: request.autostart)
            try meta.save()
            status = "Building cloud-init seed…"
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
            try await LaunchAgent.start(name)
        }
        await refresh()
    }

    func start(_ vm: String) async {
        await perform(vm, "Starting…") {
            let tart = try requireTart()
            guard let meta = VMMeta.load(vm) else { throw ProxmacsError("missing metadata") }
            try LaunchAgent.write(tart: tart, meta: meta)  // pick up any metadata changes
            try await LaunchAgent.start(vm)
        }
    }

    func stop(_ vm: String) async {
        await perform(vm, "Stopping…") {
            try await requireTart().stop(vm)
        }
    }

    func delete(_ vm: String) async {
        await perform(vm, "Deleting…") {
            let tart = try requireTart()
            if vms.first(where: { $0.name == vm })?.isRunning == true {
                try? await tart.stop(vm, timeout: 10)
            }
            await LaunchAgent.remove(vm)
            if FileManager.default.fileExists(atPath: Paths.tartVMDir(vm).path) {
                try await tart.delete(vm)
            }
            try FileManager.default.removeItem(at: Paths.vmDir(vm))
            ips[vm] = nil
        }
    }

    func setAutostart(_ vm: String, _ enabled: Bool) async {
        await perform(vm, "Saving…") {
            guard var meta = VMMeta.load(vm) else { return }
            meta.autostart = enabled
            try meta.save()
            try LaunchAgent.write(tart: try requireTart(), meta: meta)
        }
    }

    func setBackupPolicy(_ vm: String, _ policy: BackupPolicy) {
        guard var meta = VMMeta.load(vm) else { return }
        meta.backup = policy
        do { try meta.save() } catch { lastError = error.localizedDescription }
        if let index = vms.firstIndex(where: { $0.name == vm }) { vms[index].meta = meta }
    }

    func backup(_ vm: String) async {
        await perform(vm, "Backing up…") {
            let tart = try requireTart()
            let running = vms.first(where: { $0.name == vm })?.isRunning ?? false
            let keep = VMMeta.load(vm)?.backup.keep ?? 5
            let info = try await BackupManager.backup(vm, running: running, tart: tart, keep: keep)
            status = info.record.consistent ? "Backup of \(vm) done" : "Backup of \(vm) done (crash-consistent: guest agent unreachable)"
        }
    }

    func restore(_ vm: String, _ backup: BackupInfo) async {
        await perform(vm, "Restoring…") {
            if vms.first(where: { $0.name == vm })?.isRunning == true {
                throw ProxmacsError("Stop the VM before restoring")
            }
            try await BackupManager.restore(vm, from: backup, tart: try requireTart())
            status = "Restored \(vm) from \(backup.record.date.formatted())"
        }
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

    // MARK: - Host helpers

    func openConsole(_ vm: String) {
        let log = (try? String(contentsOf: Paths.runLog(vm), encoding: .utf8)) ?? ""
        guard let match = log.matches(of: #/Successfully open pty (\S+)/#).last else {
            lastError = "\(vm): no serial console found in run.log (is the VM running?)"
            return
        }
        let pty = String(match.1)
        let script = Paths.vmDir(vm).appending(path: "console.command")
        let body = """
        #!/bin/sh
        printf '\\033]0;%s console\\007' '\(vm)'
        echo "Proxmacs: \(vm) serial console on \(pty). Press Enter for a login prompt; detach with Ctrl-A then K."
        exec /usr/bin/screen \(pty)

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
