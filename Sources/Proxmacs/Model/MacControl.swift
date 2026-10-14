import Foundation

/// Bridge to existing system services. Linux VMs keep the upstream lifecycle.
enum MacControl {
    struct Settings: Decodable {
        var powerCommand: String
        var ownerHelper: String
        var ownerUser: String
        var reservedMemoryMB: Int?
    }
    static func settings() throws -> Settings {
        let file = Paths.support.appending(path: "external-control.json")
        guard let data = try? Data(contentsOf: file), let settings = try? JSONDecoder().decode(Settings.self, from: data),
              settings.powerCommand.hasPrefix("/"), settings.ownerHelper.hasPrefix("/"), !settings.ownerUser.isEmpty else {
            throw ProxmacsError("Configure external-control.json before managing system VM services")
        }
        return settings
    }
    static func external(_ name: String) -> Bool { ExternalMonitor.machines[name] != nil }
    static func isMac(_ name: String) -> Bool {
        guard let data = try? Data(contentsOf: Paths.tartVMDir(name).appending(path: "config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return config["os"] as? String == "darwin"
    }
    static func allows(method: String, path: String) -> Bool {
        let parts = (path.removingPercentEncoding ?? path).split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "vms", external(parts[2]) else { return true }
        let operation = parts.count > 3 ? parts[3] : ""
        if method == "PATCH", parts.count == 3 { return true }
        if method == "GET" || method == "HEAD" { return operation != "guest" }
        if method == "POST", parts.count == 5, operation == "console", parts[4] == "session" { return true }
        if method == "POST", parts.count == 4, ["start", "stop", "poweroff", "reboot", "reset", "backup"].contains(operation) { return true }
        if method == "PUT", parts.count == 4, operation == "hardware" { return true }
        return operation == "backups" || operation == "offsite"
    }
    static func power(_ name: String, _ action: String) async throws {
        guard external(name) else { throw ProxmacsError("Not a system-managed VM") }
        try await Shell.check(settings().powerCommand, [action, name], timeout: 210)
    }
    static func requireStopped(_ name: String) async throws {
        guard let vm = ExternalMonitor.machines[name], await ExternalMonitor.state(vm) == "stopped" else {
            throw ProxmacsError("Shut down the VM before changing its configuration")
        }
        // Prevent launchd from racing the configuration write.
        try Data().write(to: Paths.tartVMDir(name).appending(path: ".paused"))
    }
    static func ownerTart(_ name: String, _ args: [String]) async throws -> String {
        let config = try settings()
        return try await Shell.check("/usr/bin/sudo", ["-n", "-H", "-u", config.ownerUser, config.ownerHelper, name] + args, timeout: 180)
    }
    static func updateDiskSize(_ name: String, _ gb: Int) throws {
        let url = Paths.support.appending(path: "external-vms.json")
        var machines = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: [String: Any]]
        machines[name]?["diskGB"] = gb
        try JSONSerialization.data(withJSONObject: machines, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    static func whileStopped<T>(_ name: String, operation: () async throws -> T) async throws -> T {
        guard let vm = ExternalMonitor.machines[name] else { return try await operation() }
        let current = await ExternalMonitor.state(vm)
        guard current == "running" || current == "stopped" else { throw ProxmacsError("Cannot determine VM state") }
        let resume = current == "running" && !FileManager.default.fileExists(atPath: Paths.tartVMDir(name).appending(path: ".paused").path)
        if current == "running" { try await power(name, "stop") }
        try await requireStopped(name)
        do {
            let result = try await operation()
            if resume { try await power(name, "start") }
            return result
        } catch {
            if resume { try? await power(name, "start") }
            throw error
        }
    }
    static func repairPermissions(_ name: String) throws {
        for file in BackupManager.files(of: name) {
            let path = Paths.tartVMDir(name).appending(path: file).path
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() {
                try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: Paths.tartVMDir(name).appending(path: "nvram.bin").path)
    }

}
