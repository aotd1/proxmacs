import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import NIOPosix

/// Short-lived runtime credentials written by the VM supervisor, never VM metadata or a URL.
enum GraphicalConsole {
    struct Endpoint: Decodable, Equatable {
        var pid: Int32
        var port: Int
        var password: String
    }

    static func endpoint(_ name: String) throws -> Endpoint {
        guard let file = ExternalMonitor.machines[name]?.consoleFile, file.hasPrefix("/") else {
            throw ProxmacsError("Graphical console is not configured. Install the console launcher and restart this VM.")
        }
        let fd = open(file, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProxmacsError("Console is not ready. Start the VM with the console launcher enabled.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var attrs = stat()
        guard fstat(fd, &attrs) == 0, attrs.st_mode & S_IFMT == S_IFREG,
              attrs.st_mode & 0o027 == 0, attrs.st_size > 0, attrs.st_size <= 4096,
              let data = try handle.read(upToCount: 4097),
              let result = try? JSONDecoder().decode(Endpoint.self, from: data),
              result.pid > 0, (1...65535).contains(result.port),
              !result.password.isEmpty, result.password.utf8.count <= 512,
              VMProcess.lockPID(name) == result.pid else {
            throw ProxmacsError("Console session is stale or unsafe. Wait for the VM to finish starting, then reconnect.")
        }
        return result
    }

    static func sameOrigin(_ origin: String?, authority: String?, tls: Bool) -> Bool {
        guard let origin, let authority, let parsed = URLComponents(string: origin),
              let target = URLComponents(string: "\(tls ? "https" : "http")://\(authority)"),
              parsed.scheme == target.scheme, parsed.host?.lowercased() == target.host?.lowercased(),
              (parsed.port ?? (tls ? 443 : 80)) == (target.port ?? (tls ? 443 : 80)),
              parsed.user == nil, parsed.password == nil, parsed.path.isEmpty,
              parsed.query == nil, parsed.fragment == nil else { return false }
        return true
    }

    static func authorize(_ request: Request, tls: Bool) async -> Bool {
        guard sameOrigin(request.headers[.origin], authority: request.head.authority, tls: tls) else { return false }
        return await SessionStore.shared.isValid(request.cookies[SessionStore.cookieName]?.value)
    }

    static func run(name: String, session: String?, inbound: WebSocketInboundStream,
                    outbound: WebSocketOutboundWriter) async throws {
        do {
            let endpoint = try endpoint(name)
            let tcp: NIOAsyncChannel<ByteBuffer, ByteBuffer> = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectTimeout(.seconds(5))
                .connect(to: SocketAddress(ipAddress: "127.0.0.1", port: endpoint.port)) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
            try await tcp.executeThenClose { input, output in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await data in input { try await outbound.write(.binary(data)) }
                    }
                    group.addTask {
                        for try await message in inbound.messages(maxSize: 1 << 20) {
                            guard case .binary(let data) = message else {
                                throw ProxmacsError("The graphical console requires binary messages")
                            }
                            try await output.write(data)
                        }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(2))
                            guard await SessionStore.shared.isValid(session),
                                  (try? self.endpoint(name)) == endpoint else {
                                throw ProxmacsError("Console session ended")
                            }
                        }
                    }
                    do {
                        try await group.next()
                        group.cancelAll()
                        // Wake both readers before leaving the task group.
                        try? await tcp.channel.close()
                        try? await outbound.close(.normalClosure, reason: "Console disconnected")
                    } catch {
                        group.cancelAll()
                        try? await tcp.channel.close()
                        try? await outbound.close(.policyViolation, reason: "Console session ended")
                        throw error
                    }
                }
            }
        } catch {
            // Do not include endpoint/credentials or raw connection errors in browser messages or logs.
            try? await outbound.close(.unexpectedServerError, reason: "Console unavailable; reconnect after the VM starts")
        }
    }
}
