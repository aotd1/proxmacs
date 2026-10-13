import Foundation

/// Per-VM supervisor run by the LaunchAgent (`Proxmacs cli run-vm <name>`).
///
/// Tart's own `--serial` pty is unusable for later attachment: Tart closes the slave side right
/// away, so the master hangs up before anyone connects. Instead we own the pty (keeping both
/// ends open), hand the slave to `tart run --serial-path`, and relay the master to clients over
/// a Unix socket (`vms/<name>/console.sock`), keeping a scrollback in `console.log`.
enum VMRunner {
    /// Unix socket paths are limited to 104 bytes, so sockets live in a short per-user directory
    /// rather than next to the VM's data.
    static func socketPath(_ vm: String) -> URL {
        let dir = URL(fileURLWithPath: "/tmp/proxmacs-\(getuid())", isDirectory: true)
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            mkdir(dir.path, 0o700)
        } else if st.st_uid != getuid() || (st.st_mode & S_IFMT) != S_IFDIR {
            // Someone else owns it: fall back to the (longer) per-user temporary directory.
            return FileManager.default.temporaryDirectory.appending(path: "proxmacs-\(vm).sock")
        }
        return dir.appending(path: "\(vm).sock")
    }
    static func consoleLog(_ vm: String) -> URL { Paths.vmDir(vm).appending(path: "console.log") }
    private static let maxLogSize = 1 << 20

    static func run(_ vm: String) throws -> Never {
        guard var meta = VMMeta.load(vm) else { throw ProxmacsError("No VM named \(vm)") }
        guard let tart = Tart.locate() else { throw ProxmacsError("tart not found") }
        try waitForStorage()
        if meta.seedPending {
            // This boot picks up the rebuilt seed.
            meta.seedPending = false
            try? meta.save()
        }

        // 1. Our own pty; raw mode on the VM side so nothing is echoed or translated.
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw ProxmacsError("openpty failed") }
        var attrs = termios()
        tcgetattr(slave, &attrs)
        cfmakeraw(&attrs)
        tcsetattr(slave, TCSANOW, &attrs)
        let slavePath = String(cString: name)

        // 2. Console fan-out: master → log + clients; clients → master.
        let hub = ConsoleHub(master: master, log: consoleLog(vm))
        try hub.listen(on: socketPath(vm))

        // 3. tart run, with the serial port on our pty.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tart.path)
        process.arguments = LaunchAgent.tartRunArguments(meta: meta, serialPath: slavePath)
        process.environment = Tart.environment
        try process.run()
        print("proxmacs: started tart (pid \(process.processIdentifier)), console on \(slavePath)")

        // Forward launchd's SIGTERM (bootout) / SIGINT to tart so the guest shuts down cleanly.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(process.processIdentifier, sig) }
            source.resume()
            hub.retain(source)
        }

        process.waitUntilExit()
        unlink(socketPath(vm).path)
        print("proxmacs: tart exited with status \(process.terminationStatus)")
        _ = slave  // keep the slave open for the VM's whole lifetime
        exit(process.terminationStatus)
    }

    /// At login an external drive may mount after the LaunchAgent starts: give it a few minutes.
    private static func waitForStorage(timeout: TimeInterval = 180) throws {
        guard !Storage.isAvailable(.vms) else { return }
        print("proxmacs: waiting for \(Storage.url(.vms).path)…")
        let deadline = Date().addingTimeInterval(timeout)
        while !Storage.isAvailable(.vms) {
            guard Date() < deadline else { throw Storage.unavailableError(.vms) }
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

/// Owns the pty master: drains it continuously (so the guest never blocks), appends to the
/// scrollback log and broadcasts to connected socket clients.
final class ConsoleHub: @unchecked Sendable {
    private let master: Int32
    private let logURL: URL
    private let lock = NSLock()
    private var clients: Set<Int32> = []
    private var retained: [AnyObject] = []
    private var logHandle: FileHandle?

    init(master: Int32, log: URL) {
        self.master = master
        self.logURL = log
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: log)
        _ = try? logHandle?.seekToEnd()
        Thread.detachNewThread { self.pumpMaster() }
    }

    func retain(_ object: AnyObject) { lock.withLock { retained.append(object) } }

    func listen(on url: URL) throws {
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw ProxmacsError("socket path too long: \(url.path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw ProxmacsError("cannot listen on \(url.path): \(String(cString: strerror(errno)))") }
        chmod(url.path, 0o600)
        Thread.detachNewThread { self.acceptLoop(fd) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue } else { return } }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.withLock { _ = clients.insert(client) }
            Thread.detachNewThread { self.pumpClient(client) }
        }
    }

    /// Client keystrokes → pty master.
    private func pumpClient(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            writeAll(master, buffer, n)
        }
        lock.withLock { _ = clients.remove(client) }
        close(client)
    }

    /// Guest output → scrollback log + every client.
    private func pumpMaster() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            let data = Data(buffer[0..<n])
            appendLog(data)
            let targets = lock.withLock { clients }
            for client in targets where !writeAll(client, buffer, n) {
                lock.withLock { _ = clients.remove(client) }
                shutdown(client, SHUT_RDWR)
            }
        }
    }

    private func appendLog(_ data: Data) {
        guard let logHandle else { return }
        logHandle.write(data)
        // Keep roughly the last 512 KiB once the log passes 1 MiB.
        if let size = try? logHandle.offset(), size > 1 << 20,
           let full = try? Data(contentsOf: logURL) {
            try? full.suffix(512 * 1024).write(to: logURL)
            try? logHandle.seekToEnd()
        }
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ bytes: [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, count - offset) }
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }
}

/// Client side of a VM console socket (used by the web UI bridge and `cli console`).
enum ConsoleClient {
    static func connect(_ vm: String) -> Int32? {
        let url = VMRunner.socketPath(vm)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Last `bytes` of the scrollback, so a new viewer sees recent output immediately.
    /// Terminal status queries (cursor position, device attributes) are stripped: a terminal
    /// replaying them would answer, and the answers would be typed into the guest.
    static func scrollback(_ vm: String, bytes: Int = 16 * 1024) -> Data {
        guard let data = try? Data(contentsOf: VMRunner.consoleLog(vm)) else { return Data() }
        var text = [UInt8](data.suffix(bytes))
        let queries: [[UInt8]] = ["\u{1B}[6n", "\u{1B}[5n", "\u{1B}[c", "\u{1B}[0c", "\u{1B}[>c", "\u{1B}[18t"].map { Array($0.utf8) }
        for query in queries {
            var result: [UInt8] = []
            result.reserveCapacity(text.count)
            var i = 0
            while i < text.count {
                if text[i] == 0x1B, i + query.count <= text.count, Array(text[i..<(i + query.count)]) == query {
                    i += query.count
                } else {
                    result.append(text[i])
                    i += 1
                }
            }
            text = result
        }
        return Data(text)
    }
}
