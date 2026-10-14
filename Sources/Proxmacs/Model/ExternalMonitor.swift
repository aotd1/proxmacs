import Foundation

/// Opt-in view of VMs owned by existing system services. Never starts a second VM runner.
enum ExternalMonitor {
    static var enabled: Bool {
        FileManager.default.fileExists(atPath: Paths.support.appending(path: "external-vms.json").path)
    }
    struct VM: Decodable {
        var service: String
        var ip: String
        var diskGB: Int?
        var consoleFile: String? = nil
    }
    static var machines: [String: VM] {
        (try? JSONDecoder().decode([String: VM].self, from: Data(contentsOf: Paths.support.appending(path: "external-vms.json")))) ?? [:]
    }

    static func state(serviceOutput: String, executable: String) -> String {
        let fields = serviceOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.contains("state = running") else { return "stopped" }
        // launchd also reports the shell waiting on .paused as running.
        if executable.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/tart") { return "running" }
        if executable.contains("bash") { return "stopped" }
        return "unknown"
    }

    static func state(_ vm: VM) async -> String {
        // Tart owns the POSIX config lock even when launchd's immediate child is a VNC supervisor.
        if let name = machines.first(where: { $0.value.service == vm.service })?.key,
           let pid = VMProcess.lockPID(name), pid > 0 { return "running" }
        guard let result = try? await Shell.run("/bin/launchctl", ["print", vm.service], timeout: 3), result.succeeded else { return "unknown" }
        let pid = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid = ") }.flatMap { Int($0.dropFirst(6)) }
        let executable: String
        if let pid { executable = (try? await Shell.check("/bin/ps", ["-p", String(pid), "-o", "comm="], timeout: 3)) ?? "" }
        else { executable = "" }
        if let name = machines.first(where: { $0.value.service == vm.service })?.key,
           let pid = VMProcess.lockPID(name), pid == 0 { return "stopped" }
        return state(serviceOutput: result.stdout, executable: executable)
    }
}
