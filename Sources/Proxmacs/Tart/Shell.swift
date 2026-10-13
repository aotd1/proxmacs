import Foundation

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }
}

struct CommandError: LocalizedError {
    var command: String
    var result: CommandResult

    var errorDescription: String? {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        return "`\(command)` failed (\(result.status)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

enum Shell {
    /// Runs a process to completion off the main thread. `timeout` terminates it (status then reflects SIGTERM).
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil,
                    environment: [String: String]? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { process.terminate() }
                    }
                }

                // Drain both pipes concurrently so neither can fill up and block the child.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Like `run`, but throws `CommandError` on a non-zero exit status.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil,
                      environment: [String: String]? = nil) async throws -> String {
        let result = try await run(executable, arguments, timeout: timeout, environment: environment)
        guard result.succeeded else {
            throw CommandError(command: ([executable] + arguments).joined(separator: " "), result: result)
        }
        return result.stdout
    }
}
