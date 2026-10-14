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

/// Progress while an image is prepared: a message and, while downloading or converting, a fraction.
typealias ImageReport = @Sendable (_ message: String, _ fraction: Double?) -> Void

/// An image in the cache directory, or one of the catalog that can be downloaded.
struct ImageEntry {
    var id: String
    var name: String
    /// nil for imported images.
    var catalog: CatalogImage?
    var raw: URL
    var cached: Bool
    /// Disk size of the image (what a VM needs at least), once cached.
    var virtualBytes: Int64?
    /// Space the sparse raw file takes.
    var diskBytes: Int64?
}

/// Base disk images (converted to raw, cached) and the guest agent packages.
enum ImageStore {
    static let agentVersion = "0.15.0"
    /// Both packages go into every seed; the guest installs the one its package manager takes.
    static let agentPackages = ["deb", "rpm"].map { kind in
        (url: URL(string: "https://github.com/openai/tart-guest-agent/releases/download/v\(agentVersion)/tart-guest-agent_\(agentVersion)_linux_arm64.\(kind)")!,
         file: Paths.images.appending(path: "tart-guest-agent_\(agentVersion)_linux_arm64.\(kind)"))
    }

    static func entries() -> [ImageEntry] {
        let catalog = ImageCatalog.all.map { image in
            entry(id: image.id, name: image.name, catalog: image, raw: image.raw)
        }
        return catalog + imported().map { entry(id: $0.lastPathComponent, name: $0.lastPathComponent, catalog: nil, raw: $0) }
    }

    private static func entry(id: String, name: String, catalog: CatalogImage?, raw: URL) -> ImageEntry {
        let cached = FileManager.default.fileExists(atPath: raw.path)
        return ImageEntry(id: id, name: name, catalog: catalog, raw: raw, cached: cached,
                          virtualBytes: cached ? FileCopy.size(of: raw) : nil,
                          diskBytes: cached ? FileCopy.allocatedSize(of: raw) : nil)
    }

    /// Raw images imported from local files (everything in the cache that isn't a catalog image).
    static func imported() -> [URL] {
        let catalog = Set(ImageCatalog.all.map(\.raw.lastPathComponent))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.images.path)) ?? []
        return files.filter { $0.hasSuffix(".raw") && !catalog.contains($0) }.sorted()
            .map { Paths.images.appending(path: $0) }
    }

    /// Returns the cached raw image, downloading and converting it if needed. Concurrent calls for the
    /// same image share one download.
    static func base(_ image: CatalogImage, report: @escaping ImageReport) async throws -> URL {
        try await ImageDownloads.shared.fetch(image, report: report)
    }

    fileprivate static func prepare(_ image: CatalogImage, report: @escaping ImageReport) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: image.raw.path) {
            removeLeftovers(image)
            return image.raw
        }
        try fm.createDirectory(at: Paths.images, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: image.download) }

        report("Looking up \(image.name)…", nil)
        let url = try await resolve(image)
        try await Downloader.download(url, to: image.download) { fraction in
            report("Downloading \(image.name)… \(percent(fraction))", fraction)
        }
        if QCOW2Converter.isQCOW2(image.download) {
            try await convert(image.download, to: image.raw) { fraction in
                report("Converting \(image.name) to raw… \(percent(fraction))", fraction)
            }
        } else {
            try fm.moveItem(at: image.download, to: image.raw)
        }
        removeLeftovers(image)
        return image.raw
    }

    private static func removeLeftovers(_ image: CatalogImage) {
        for file in image.legacyFiles {
            try? FileManager.default.removeItem(at: Paths.images.appending(path: file))
        }
    }

    /// The download URL; for an index source, the newest matching file in the listing.
    static func resolve(_ image: CatalogImage) async throws -> URL {
        switch image.source {
        case .url(let url):
            return url
        case .index(let index, let pattern):
            let (data, response) = try await URLSession.shared.data(from: index)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ProxmacsError("Cannot list \(index.absoluteString): HTTP \(http.statusCode)")
            }
            let listing = String(decoding: data, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: pattern)
            let names = Set(regex.matches(in: listing, range: NSRange(listing.startIndex..., in: listing))
                .compactMap { Range($0.range, in: listing).map { String(listing[$0]) } })
            guard let newest = names.max(by: { $0.localizedStandardCompare($1) == .orderedAscending }),
                  let url = URL(string: newest, relativeTo: index) else {
                throw ProxmacsError("No \(image.name) image found at \(index.absoluteString)")
            }
            return url.absoluteURL
        }
    }

    /// Imports a local .qcow2 or .raw image, returning the cached raw copy.
    static func importLocal(_ source: URL, report: @escaping ImageReport) async throws -> URL {
        let name = source.lastPathComponent.lowercased()
        if name.contains("amd64") || name.contains("x86_64") || name.contains("x86-64") {
            throw ImageError.wrongArchitecture(source.lastPathComponent)
        }
        let destination = Paths.images.appending(path: source.deletingPathExtension().lastPathComponent + ".raw")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        if QCOW2Converter.isQCOW2(source) {
            try await convert(source, to: destination) { report("Converting qcow2 → raw… \(percent($0))", $0) }
        } else {
            report("Copying image…", nil)
            try FileManager.default.copyItem(at: source, to: destination)  // APFS clone when possible
        }
        return destination
    }

    /// Removes a cached image: a catalog image's download (it can be downloaded again) or an imported image.
    static func delete(_ id: String) throws {
        if let image = ImageCatalog.find(id) {
            guard !ImageDownloads.shared.isActive(image.id) else { throw ProxmacsError("\(image.name) is being downloaded") }
            guard FileManager.default.fileExists(atPath: image.raw.path) else { throw ProxmacsError("\(image.name) is not downloaded") }
            try FileManager.default.removeItem(at: image.raw)
            removeLeftovers(image)
        } else if let file = imported().first(where: { $0.lastPathComponent == id }) {
            try FileManager.default.removeItem(at: file)
        } else {
            throw ProxmacsError("No image \(id)")
        }
    }

    static func agentPackages(report: @escaping ImageReport) async throws -> [URL] {
        for package in agentPackages where !FileManager.default.fileExists(atPath: package.file.path) {
            try await Downloader.download(package.url, to: package.file) {
                report("Downloading guest agent (.\(package.file.pathExtension))… \(percent($0))", $0)
            }
        }
        return agentPackages.map(\.file)
    }

    private static func convert(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await Task.detached(priority: .userInitiated) {
                try QCOW2Converter.convert(source: source, destination: partial, progress: progress)
            }.value
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
}

/// Image downloads in progress. A second request for an image that is already downloading waits
/// for the first one and gets its progress, so the image is fetched once.
final class ImageDownloads: @unchecked Sendable {
    static let shared = ImageDownloads()

    private let lock = NSLock()
    private var tasks: [String: Task<URL, Error>] = [:]
    private var listeners: [String: [UUID: ImageReport]] = [:]
    private var latest: [String: (message: String, fraction: Double?)] = [:]

    func isActive(_ id: String) -> Bool { lock.withLock { tasks[id] != nil } }

    /// Image id → the latest progress message and fraction.
    func progress() -> [String: (message: String, fraction: Double?)] { lock.withLock { latest } }

    func fetch(_ image: CatalogImage, report: @escaping ImageReport) async throws -> URL {
        let token = UUID()
        let (task, joined) = lock.withLock { () -> (Task<URL, Error>, Bool) in
            listeners[image.id, default: [:]][token] = report
            if let task = tasks[image.id] { return (task, true) }
            let task = Task<URL, Error> { [self] in
                defer { finish(image.id) }
                return try await ImageStore.prepare(image) { [self] message, fraction in broadcast(image.id, message, fraction) }
            }
            tasks[image.id] = task
            return (task, false)
        }
        if joined {
            report(latest(image.id)?.message ?? "Waiting for the \(image.name) download…", latest(image.id)?.fraction)
        }
        defer { lock.withLock { _ = listeners[image.id]?.removeValue(forKey: token) } }
        return try await task.value
    }

    private func latest(_ id: String) -> (message: String, fraction: Double?)? { lock.withLock { latest[id] } }

    private func broadcast(_ id: String, _ message: String, _ fraction: Double?) {
        let targets = lock.withLock { () -> [ImageReport] in
            latest[id] = (message, fraction)
            return Array(listeners[id, default: [:]].values)
        }
        for report in targets { report(message, fraction) }
    }

    private func finish(_ id: String) {
        lock.withLock {
            tasks[id] = nil
            latest[id] = nil
        }
    }
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
