import Foundation

/// Each VM runs as `tart run` under its own user LaunchAgent, so VMs outlive the menubar app
/// and can start at login (`RunAtLoad`).
enum LaunchAgent {
    static func label(_ vm: String) -> String { "dev.proxmacs.vm.\(vm)" }
    static func plistURL(_ vm: String) -> URL { Paths.launchAgents.appending(path: "\(label(vm)).plist") }

    private static var domain: String { "gui/\(getuid())" }
    private static let launchctl = "/bin/launchctl"

    static func runArguments(tart: Tart, meta: VMMeta) -> [String] {
        var args = [tart.path, "run", meta.name, "--no-graphics", "--serial", "--disk", "\(Paths.seedISO(meta.name).path):ro"]
        if case .bridged(let iface) = meta.network {
            args.append("--net-bridged=\(iface)")
        }
        return args
    }

    static func write(tart: Tart, meta: VMMeta) throws {
        var env = [
            "HOME": Paths.home.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            // Makes Foundation unbuffer stdout so the "open pty" line reaches run.log immediately.
            "NSUnbufferedIO": "YES",
        ]
        if let tartHome = ProcessInfo.processInfo.environment["TART_HOME"] { env["TART_HOME"] = tartHome }

        let plist: [String: Any] = [
            "Label": label(meta.name),
            "ProgramArguments": runArguments(tart: tart, meta: meta),
            "RunAtLoad": meta.autostart,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "EnvironmentVariables": env,
            "StandardOutPath": Paths.runLog(meta.name).path,
            "StandardErrorPath": Paths.runLog(meta.name).path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL(meta.name), options: .atomic)
    }

    static func isLoaded(_ vm: String) async -> Bool {
        (try? await Shell.run(launchctl, ["print", "\(domain)/\(label(vm))"]))?.succeeded ?? false
    }

    /// (Re)loads the job from its plist and starts it. Call only while the VM is stopped.
    static func start(_ vm: String) async throws {
        // Truncate the log so the console lookup only sees this boot's pty.
        try? Data().write(to: Paths.runLog(vm))
        // Reload so plist edits (network, autostart) take effect.
        await unload(vm)
        var lastError: Error?
        for _ in 0..<5 {
            do {
                try await Shell.check(launchctl, ["bootstrap", domain, plistURL(vm).path])
                lastError = nil
                break
            } catch {
                // bootout completes asynchronously; bootstrap fails with EIO until it has.
                lastError = error
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        if let lastError { throw lastError }
        try await Shell.check(launchctl, ["kickstart", "\(domain)/\(label(vm))"])
    }

    /// Unloads the job, killing `tart run` if it is still alive.
    static func unload(_ vm: String) async {
        _ = try? await Shell.run(launchctl, ["bootout", "\(domain)/\(label(vm))"])
    }

    static func remove(_ vm: String) async {
        await unload(vm)
        try? FileManager.default.removeItem(at: plistURL(vm))
    }
}
