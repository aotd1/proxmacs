import Foundation

enum ImageError: LocalizedError {
    case wrongArchitecture(String)

    var errorDescription: String? {
        switch self {
        case .wrongArchitecture(let name):
            "\(name) looks like an x86-64 image. Apple Silicon VMs can only boot arm64 images (e.g. debian-13-genericcloud-arm64.qcow2)."
        }
    }
}

/// Base disk images (converted to raw, cached) and the guest agent package.
enum ImageStore {
    static let debianURL = URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2")!
    static let debianQCOW2 = Paths.images.appending(path: "debian-13-genericcloud-arm64.qcow2")
    static let debianRaw = Paths.images.appending(path: "debian-13-arm64.raw")

    static let agentVersion = "0.15.0"
    static let agentURL = URL(string: "https://github.com/openai/tart-guest-agent/releases/download/v\(agentVersion)/tart-guest-agent_\(agentVersion)_linux_arm64.deb")!
    static let agentDeb = Paths.images.appending(path: "tart-guest-agent_\(agentVersion)_linux_arm64.deb")

    /// Returns the cached Debian 13 arm64 raw image, downloading and converting it if needed.
    static func debianBase(status: @escaping @Sendable (String) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: debianRaw.path) { return debianRaw }
        if !FileManager.default.fileExists(atPath: debianQCOW2.path) {
            try await Downloader.download(debianURL, to: debianQCOW2) { status("Downloading Debian 13… \(percent($0))") }
        }
        try await convert(debianQCOW2, to: debianRaw, status: status)
        return debianRaw
    }

    /// Imports a local .qcow2 or .raw image, returning the cached raw copy.
    static func importLocal(_ source: URL, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        let name = source.lastPathComponent.lowercased()
        if name.contains("amd64") || name.contains("x86_64") || name.contains("x86-64") {
            throw ImageError.wrongArchitecture(source.lastPathComponent)
        }
        let destination = Paths.images.appending(path: source.deletingPathExtension().lastPathComponent + ".raw")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        if QCOW2Converter.isQCOW2(source) {
            try await convert(source, to: destination, status: status)
        } else {
            status("Copying image…")
            try FileManager.default.copyItem(at: source, to: destination)  // APFS clone when possible
        }
        return destination
    }

    static func agentPackage(status: @escaping @Sendable (String) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: agentDeb.path) { return agentDeb }
        try await Downloader.download(agentURL, to: agentDeb) { status("Downloading guest agent… \(percent($0))") }
        return agentDeb
    }

    private static func convert(_ source: URL, to destination: URL, status: @escaping @Sendable (String) -> Void) async throws {
        let partial = destination.appendingPathExtension("partial")
        try await Task.detached(priority: .userInitiated) {
            try QCOW2Converter.convert(source: source, destination: partial) { status("Converting qcow2 → raw… \(percent($0))") }
        }.value
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
}

/// URLSession download with progress, moved atomically into place on success.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, onProgress: @escaping (Double) -> Void) async throws {
        let delegate = Downloader(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "")"])
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
