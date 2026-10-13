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
                    [--user U] [--ssh-keys FILE] [--ip CIDR [--gateway IP] [--dns IP,IP]]
      edit <name>   hardware (VM stopped): [--cpus N] [--memory MB] [--disk GB] [--nat | --bridged <iface>]
                    cloud-init (applied on next start): [--user U] [--password | --no-password]
                    [--ssh-keys FILE] [--dhcp | --ip CIDR [--gateway IP] [--dns IP,IP]]
      start|stop|delete|backup <name>
      ip <name> [--wait SECONDS]
      backups <name>
      restore <name> [index]      (0 = newest, as listed by `backups`)

      targets
      target-add smb <name> <smb://user@host/share[/path]> [--keep N]        (prompts for the password)
      target-add pbs <name> --host H --datastore D --auth-id user@realm!token
                     [--port 8007] [--namespace NS] [--fingerprint aa:bb:..] [--keep N]  (prompts for the token secret)
      target-rm|target-test <target>
      push <name> <target> [index]     upload a local backup (default newest)
      remote <target> <name>           list remote snapshots
      pull <target> <name> [id]        download a snapshot into local backups (default newest);
                                       recreates the VM if it doesn't exist

      storage                          show where VM disks and local backups are stored
      storage vms|backups <folder>     move them to a folder, e.g. on an external APFS drive
      storage vms|backups --default    move them back to the internal disk

      console <name>                   attach to the serial console (Ctrl-] detaches)
      web-passwd [--stdin]             set the web UI admin password
      serve                            run the web UI headless (no menubar)
    """

    static func run(_ args: [String]) -> Never {
        if args.first == "run-vm", args.count > 1 {
            do { try VMRunner.run(args[1]) } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if args.first == "console", args.count > 1 {
            attachConsole(args[1])
        }
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
        /// One OpenSSH public key per line; `-` reads stdin.
        func sshKeys(_ path: String) throws -> [String] {
            let text = path == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        func guestNetwork(_ base: GuestNetwork) -> GuestNetwork {
            if args.contains("--dhcp") { return GuestNetwork() }
            guard let address = option("--ip") else { return base }
            return GuestNetwork(dhcp: false, address: address, gateway: option("--gateway"),
                                dns: option("--dns")?.split(separator: ",").map(String.init) ?? [])
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
                startNow: !args.contains("--no-start"),
                user: option("--user") ?? "debian",
                sshKeys: try option("--ssh-keys").map(sshKeys),
                guestNetwork: guestNetwork(GuestNetwork())
            )
            try await state.create(request)
            print("created \(vm) (\(network.label))")

        case "edit":
            let vm = try name()
            guard let meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
            let network: NetworkMode? = if args.contains("--nat") {
                .nat
            } else {
                option("--bridged").map { .bridged(interface: $0) }
            }
            let hardware = HardwareChange(cpus: option("--cpus").flatMap(Int.init), memoryMB: option("--memory").flatMap(Int.init),
                                          diskGB: option("--disk").flatMap(Int.init), network: network)
            var edited = false
            if hardware.cpus != nil || hardware.memoryMB != nil || hardware.diskGB != nil || hardware.network != nil {
                try await state.editHardware(vm, hardware)
                edited = true
            }
            let cloudFlags = ["--user", "--password", "--no-password", "--ssh-keys", "--dhcp", "--ip"]
            if cloudFlags.contains(where: args.contains) {
                let current = meta.effectiveCloudInit
                var password = PasswordChange.keep
                if args.contains("--no-password") {
                    password = .remove
                } else if args.contains("--password") {
                    let first = prompt("New console password for \(option("--user") ?? current.user): ")
                    guard first == prompt("Repeat: ") else { throw ProxmacsError("Passwords don't match") }
                    password = .set(first)
                }
                try await state.editCloudInit(vm, user: option("--user") ?? current.user, password: password,
                                              sshKeys: try option("--ssh-keys").map(sshKeys) ?? current.sshKeys,
                                              network: guestNetwork(current.network))
                edited = true
            }
            if !edited { throw ProxmacsError(usage) }

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
            try Storage.require(.backups)
            for (index, backup) in BackupManager.list(try name()).enumerated() {
                print("\(index)\t\(backup.record.date.formatted(.iso8601))\t\(backup.record.consistent ? "consistent" : "crash-consistent")")
            }

        case "restore":
            let vm = try name()
            let index = args.count > 2 ? Int(args[2]) ?? 0 : 0
            try Storage.require(.backups)
            let backups = BackupManager.list(vm)
            guard backups.indices.contains(index) else { throw ProxmacsError("no backup #\(index) for \(vm)") }
            await state.restore(vm, backups[index]); try check()

        case "targets":
            for target in TargetStore.load() {
                print([target.name, target.kind.rawValue, target.location, "keep \(target.keep)", target.id].joined(separator: "\t"))
            }

        case "target-add":
            guard args.count > 3 else { throw ProxmacsError(usage) }
            let kind = args[1], targetName = args[2]
            let keep = option("--keep").flatMap(Int.init) ?? 7
            switch kind {
            case "smb":
                _ = try SMBLocation(parsing: args[3])
                let password = prompt("SMB password (empty = none/guest): ")
                try state.addTarget(OffsiteTarget(name: targetName, kind: .smb, keep: keep, smb: SMBSettings(url: args[3])), secret: password)
            case "pbs":
                guard let host = option("--host"), let datastore = option("--datastore"), let authId = option("--auth-id") else {
                    throw ProxmacsError(usage)
                }
                let settings = PBSSettings(host: host, port: option("--port").flatMap(Int.init) ?? 8007, datastore: datastore,
                                           namespace: option("--namespace"), authId: authId, fingerprint: option("--fingerprint"))
                let secret = prompt("PBS API token secret: ")
                guard !secret.isEmpty else { throw ProxmacsError("A token secret is required") }
                try state.addTarget(OffsiteTarget(name: targetName, kind: .pbs, keep: keep, pbs: settings), secret: secret)
            default:
                throw ProxmacsError(usage)
            }
            print("added target \(targetName)")

        case "target-rm":
            guard let target = TargetStore.target(try name()) else { throw ProxmacsError("no such target") }
            try state.removeTarget(target.id)

        case "target-test":
            guard let target = TargetStore.target(try name()) else { throw ProxmacsError("no such target") }
            let result = await state.testTarget(target.id)
            print(result.message)
            if !result.ok { throw ProxmacsError("test failed") }

        case "push":
            guard args.count > 2, let target = TargetStore.target(args[2]) else { throw ProxmacsError(usage) }
            let vm = args[1]
            let index = args.count > 3 ? Int(args[3]) ?? 0 : 0
            let backups = BackupManager.list(vm)
            guard backups.indices.contains(index) else { throw ProxmacsError("no backup #\(index) for \(vm)") }
            printProgress(state)
            await state.push(vm, backup: backups[index], targetID: target.id); try check()

        case "remote":
            guard args.count > 2, let target = TargetStore.target(args[1]) else { throw ProxmacsError(usage) }
            for snapshot in try await state.remoteSnapshots(targetID: target.id, vm: args[2]) {
                print("\(snapshot.id)\t\(snapshot.time.formatted(.iso8601))")
            }

        case "pull":
            guard args.count > 2, let target = TargetStore.target(args[1]) else { throw ProxmacsError(usage) }
            let vm = args[2]
            var id = args.count > 3 ? args[3] : nil
            if id == nil { id = try await state.remoteSnapshots(targetID: target.id, vm: vm).first?.id }
            guard let id else { throw ProxmacsError("no snapshots of \(vm) on \(target.name)") }
            printProgress(state)
            await state.pull(vm, snapshotID: id, targetID: target.id); try check()

        case "storage":
            if args.count == 1 {
                for kind in StorageKind.allCases {
                    let info = Storage.info(kind)
                    var line = "\(kind.rawValue)\t\(info.path)"
                    if info.isDefault { line += "  (default)" }
                    if !info.available {
                        line += "  UNAVAILABLE (drive disconnected?)"
                    } else if let volume = info.volume {
                        line += "  [\(volume.name), \(volume.fileSystem), \(ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .file)) free]"
                    }
                    print(line)
                }
                return
            }
            guard args.count > 2, let kind = StorageKind(rawValue: args[1]) else { throw ProxmacsError(usage) }
            let plan = try await state.planStorageChange(kind, to: args[2] == "--default" ? nil : args[2])
            printProgress(state)
            try await state.changeStorage(plan)

        case "web-passwd":
            if args.contains("--stdin") {
                // For provisioning scripts: password on the first line of stdin.
                try WebAuth.setPassword(readLine(strippingNewline: true) ?? "")
                print("Password set.")
                return
            }
            let first = prompt("New web UI admin password: ")
            guard first == prompt("Repeat: ") else { throw ProxmacsError("Passwords don't match") }
            try WebAuth.setPassword(first)
            print("Password set.")

        case "serve":
            let served = AppState()
            WebServer.shared.start(state: served)
            try await Task.sleep(for: .seconds(1))
            if let error = WebServer.shared.lastError { throw ProxmacsError(error) }
            print("Proxmacs web UI on \(WebServer.shared.url ?? "?")")
            if let fingerprint = WebCertificate.fingerprint() { print("Certificate SHA-256: \(fingerprint)") }
            if !WebAuth.hasPassword { print("No admin password yet: run `Proxmacs cli web-passwd`.") }
            await WebServer.shared.wait()
            if let error = WebServer.shared.lastError { throw ProxmacsError(error) }

        default:
            throw ProxmacsError(usage)
        }
    }

    /// Interactive serial console in the current terminal. Ctrl-] detaches.
    private static func attachConsole(_ vm: String) -> Never {
        guard let fd = ConsoleClient.connect(vm) else {
            FileHandle.standardError.write(Data("error: no console for \(vm) (is it running?)\n".utf8))
            exit(1)
        }
        print("Proxmacs: \(vm) serial console. Press Enter for a login prompt; Ctrl-] to detach.\r")
        var original = termios()
        let isTTY = isatty(STDIN_FILENO) == 1
        if isTTY {
            tcgetattr(STDIN_FILENO, &original)
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        func restoreAndExit() -> Never {
            if isTTY { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
            print("\r\nProxmacs: detached.")
            exit(0)
        }
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { restoreAndExit() }
                _ = buffer.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, n) }
            }
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n <= 0 { restoreAndExit() }
            if buffer[0..<n].contains(0x1D) { restoreAndExit() }  // Ctrl-]
            _ = buffer.withUnsafeBytes { write(fd, $0.baseAddress, n) }
        }
    }

    /// Reads a secret from the terminal without echo.
    private static func prompt(_ message: String) -> String {
        guard let value = getpass(message) else { return "" }
        return String(cString: value)
    }

    /// Echoes task progress for long transfers.
    @MainActor
    private static func printProgress(_ state: AppState) {
        Task { @MainActor in
            var last = -1
            while true {
                if let task = state.tasks.first, task.status == .running, let progress = task.progress {
                    let percent = Int(progress * 100)
                    if percent / 5 != last / 5 { print("  \(percent)%"); last = percent }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
