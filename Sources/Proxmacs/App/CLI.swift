import Foundation

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "cli" {
            CLI.run(Array(args.dropFirst()))
        } else {
            ProxmacsApp.main()
        }
    }
}

/// `Proxmacs cli <command>`: scriptable access to the same AppState the menubar uses.
enum CLI {
    static let usage = """
    usage: Proxmacs cli <command>
      list
      create <name> [--nat | --bridged <iface>] [--cpus N] [--memory MB] [--disk GB]
                    [--image <file.qcow2|raw>] [--password P] [--autostart] [--no-start]
      start|stop|delete|backup <name>
      ip <name> [--wait SECONDS]
      backups <name>
      restore <name> [index]      (0 = newest, as listed by `backups`)
    """

    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            do {
                try await execute(args)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    @MainActor
    private static func execute(_ args: [String]) async throws {
        let state = AppState(autoRefresh: false)
        state.onStatus = { print($0) }
        await state.refresh()
        guard let command = args.first else { throw ProxmacsError(usage) }

        func name() throws -> String {
            guard args.count > 1 else { throw ProxmacsError(usage) }
            return args[1]
        }
        func option(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        func check() throws {
            if let error = state.lastError { throw ProxmacsError(error) }
        }

        switch command {
        case "list":
            for vm in state.vms {
                print([vm.name, vm.state, vm.meta.network.label, vm.ip ?? "-"].joined(separator: "\t"))
            }

        case "create":
            let vm = try name()
            let network: NetworkMode = if args.contains("--nat") {
                .nat
            } else if let iface = option("--bridged") {
                .bridged(interface: iface)
            } else {
                .bridged(interface: await NetworkInterfaces.defaultRoute() ?? "en0")
            }
            let request = NewVMRequest(
                name: vm,
                cpus: option("--cpus").flatMap(Int.init) ?? 2,
                memoryMB: option("--memory").flatMap(Int.init) ?? 2048,
                diskGB: option("--disk").flatMap(Int.init) ?? 20,
                network: network,
                image: option("--image").map { .local(URL(fileURLWithPath: $0)) } ?? .debian13,
                password: option("--password") ?? "",
                autostart: args.contains("--autostart"),
                startNow: !args.contains("--no-start")
            )
            try await state.create(request)
            print("created \(vm) (\(network.label))")

        case "start":
            await state.start(try name()); try check()
        case "stop":
            await state.stop(try name()); try check()
        case "delete":
            await state.delete(try name()); try check()
        case "backup":
            await state.backup(try name()); try check()

        case "ip":
            let vm = try name()
            let deadline = Date().addingTimeInterval(option("--wait").flatMap(TimeInterval.init) ?? 0)
            while true {
                if let ip = state.vms.first(where: { $0.name == vm })?.ip {
                    print(ip)
                    return
                }
                if Date() >= deadline { throw ProxmacsError("no IP for \(vm)") }
                try await Task.sleep(for: .seconds(3))
                await state.refresh()
            }

        case "backups":
            for (index, backup) in BackupManager.list(try name()).enumerated() {
                print("\(index)\t\(backup.record.date.formatted(.iso8601))\t\(backup.record.consistent ? "consistent" : "crash-consistent")")
            }

        case "restore":
            let vm = try name()
            let index = args.count > 2 ? Int(args[2]) ?? 0 : 0
            let backups = BackupManager.list(vm)
            guard backups.indices.contains(index) else { throw ProxmacsError("no backup #\(index) for \(vm)") }
            await state.restore(vm, backups[index]); try check()

        default:
            throw ProxmacsError(usage)
        }
    }
}
