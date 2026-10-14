import Foundation

/// A content-addressed, deduplicating snapshot store on an SMB share (PBS-like layout):
///
///     <share>/<subpath>/proxmacs-store/
///       chunks/<2 hex>/<sha256 hex>              DataBlob (zstd) of one 4 MiB chunk or a small file
///       snapshots/<vm>/<epoch>/manifest.json
///
/// Zero chunks are recorded in the manifest but never stored. Unchanged chunks are never re-sent.
struct ChunkStoreBackend: OffsiteBackend {
    let location: SMBLocation?
    let password: String?
    /// Store directly in a local directory (tests, external drives) instead of mounting SMB.
    var localRoot: URL?

    init(location: SMBLocation, password: String?) {
        self.location = location
        self.password = password
    }

    init(localRoot: URL) {
        location = nil
        password = nil
        self.localRoot = localRoot
    }

    private var label: String { location?.shareURL.absoluteString ?? localRoot?.path ?? "?" }

    struct Manifest: Codable {
        var vm: String
        var time: Date
        var consistent: Bool
        var diskSize: UInt64
        var chunkSize: Int
        var disk: [String]
        /// file name → chunk digest
        var files: [String: String]
        /// Extra disk images (disk1.img, …); absent in snapshots of older versions.
        var extraDisks: [Image]?

        struct Image: Codable {
            var name: String
            var size: UInt64
            var chunks: [String]
        }

        /// Every disk image: the root disk first.
        var images: [Image] { [Image(name: BackupFiles.disk, size: diskSize, chunks: disk)] + (extraDisks ?? []) }
    }

    // MARK: - OffsiteBackend

    func test() async throws -> String {
        try await withStore { root in
            let probe = root.appending(path: ".probe-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            let vms = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "snapshots").path)) ?? []
            return "Writable store at \(root.path) (\(vms.filter { !$0.hasPrefix(".") }.count) VMs)"
        }
    }

    func push(vm: String, backupDir: URL, record: BackupRecord, progress: ProgressHandler) async throws {
        try await withStore { root in
            let epoch = Int(record.date.timeIntervalSince1970)
            let snapshotDir = root.appending(path: "snapshots/\(vm)/\(epoch)", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: snapshotDir.appending(path: "manifest.json").path) {
                throw ProxmacsError("Snapshot \(vm)/\(epoch) already exists on the share")
            }

            // Chunks referenced by the previous snapshot are known to exist: skip even the stat().
            var known = Set(try latestManifest(root, vm: vm)?.images.flatMap(\.chunks) ?? [])
            let chunkers = try BackupFiles.images(in: backupDir).map { ($0, try ImageChunker(url: backupDir.appending(path: $0))) }
            let total = Double(max(chunkers.reduce(0) { $0 + $1.1.chunkCount }, 1))
            var done = 0
            var images: [Manifest.Image] = []

            for (name, chunker) in chunkers {
                var digests: [String] = []
                digests.reserveCapacity(chunker.chunkCount)
                for index in 0..<chunker.chunkCount {
                    try Task.checkCancellation()
                    let chunk = try chunker.chunk(at: index)
                    let hex = chunk.digest.hex
                    digests.append(hex)
                    if let data = chunk.data, !known.contains(hex) {
                        try storeChunk(root, hex: hex, data: data)
                        known.insert(hex)
                    }
                    done += 1
                    progress(Double(done) / total)
                }
                images.append(Manifest.Image(name: name, size: chunker.size, chunks: digests))
            }

            var files: [String: String] = [:]
            for name in BackupFiles.blobs {
                guard let data = try? Data(contentsOf: backupDir.appending(path: name)) else { continue }
                let hex = sha256(data).hex
                try storeChunk(root, hex: hex, data: data)
                files[name] = hex
            }

            let manifest = Manifest(vm: vm, time: record.date, consistent: record.consistent, diskSize: images[0].size,
                                    chunkSize: ImageChunker.chunkSize, disk: images[0].chunks, files: files,
                                    extraDisks: images.count > 1 ? Array(images.dropFirst()) : nil)
            try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            try atomicWrite(JSONEncoder.proxmacs.encode(manifest), to: snapshotDir.appending(path: "manifest.json"))
        }
    }

    func snapshots(vm: String) async throws -> [RemoteSnapshot] {
        try await withStore { root in
            try listManifests(root, vm: vm).map { RemoteSnapshot(vm: vm, time: $0.manifest.time, id: $0.id) }
        }
    }

    func pull(_ snapshot: RemoteSnapshot, into dir: URL, progress: ProgressHandler) async throws {
        try await withStore { root in
            let url = root.appending(path: "snapshots/\(snapshot.vm)/\(snapshot.id)/manifest.json")
            let manifest = try JSONDecoder.proxmacs.decode(Manifest.self, from: Data(contentsOf: url))

            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let total = Double(max(manifest.images.reduce(0) { $0 + $1.chunks.count }, 1))
            var done = 0
            for image in manifest.images {
                guard ExtraDisk.isValidFile(image.name) || image.name == BackupFiles.disk else { continue }
                let writer = try SparseImageWriter(url: dir.appending(path: image.name), size: image.size)
                for (index, hex) in image.chunks.enumerated() {
                    try Task.checkCancellation()
                    done += 1
                    let offset = UInt64(index) * UInt64(manifest.chunkSize)
                    let length = Int(min(UInt64(manifest.chunkSize), image.size - offset))
                    if isZero(hex, length: length) { continue }
                    try writer.write(loadChunk(root, hex: hex), at: offset)
                    progress(Double(done) / total)
                }
                try writer.finish()
            }

            for (name, hex) in manifest.files {
                try loadChunk(root, hex: hex).write(to: dir.appending(path: name))
            }
            let record = BackupRecord.pulled(from: snapshot, consistent: manifest.consistent, target: label)
            try JSONEncoder.proxmacs.encode(record).write(to: dir.appending(path: "backup.json"))
        }
    }

    func verify(_ snapshot: RemoteSnapshot, progress: ProgressHandler) async throws -> String {
        try await withStore { root in
            let url = root.appending(path: "snapshots/\(snapshot.vm)/\(snapshot.id)/manifest.json")
            let manifest = try JSONDecoder.proxmacs.decode(Manifest.self, from: Data(contentsOf: url))
            var unique: [String] = []
            var seen = Set<String>()
            for image in manifest.images {
                for (index, hex) in image.chunks.enumerated() {
                    let length = Int(min(UInt64(manifest.chunkSize), image.size - UInt64(index) * UInt64(manifest.chunkSize)))
                    if !isZero(hex, length: length), seen.insert(hex).inserted { unique.append(hex) }
                }
            }
            unique += manifest.files.values.filter { seen.insert($0).inserted }
            var bytes = 0
            for (index, hex) in unique.enumerated() {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: chunkURL(root, hex: hex).path) else {
                    throw ProxmacsError("Chunk \(hex) is missing")
                }
                bytes += try loadChunk(root, hex: hex).count
                progress(Double(index + 1) / Double(max(unique.count, 1)))
            }
            return "\(unique.count) chunks (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))) verified"
        }
    }

    func prune(vm: String, keep: Int) async throws {
        try await withStore { root in
            for old in try listManifests(root, vm: vm).dropFirst(max(keep, 1)) {
                try FileManager.default.removeItem(at: root.appending(path: "snapshots/\(vm)/\(old.id)"))
            }
            try collectGarbage(root)
        }
    }

    // MARK: - Store helpers

    private func withStore<T>(_ body: (URL) async throws -> T) async throws -> T {
        func prepare(_ base: URL) throws -> URL {
            let root = base.appending(path: "proxmacs-store", directoryHint: .isDirectory)
            for sub in ["chunks", "snapshots"] {
                try FileManager.default.createDirectory(at: root.appending(path: sub), withIntermediateDirectories: true)
            }
            return root
        }
        if let localRoot { return try await body(prepare(localRoot)) }
        guard let location else { throw ProxmacsError("chunk store has no location") }
        return try await SMBMount.withMount(location, password: password) { mount in
            var base = mount
            if !location.subpath.isEmpty { base = base.appending(path: location.subpath, directoryHint: .isDirectory) }
            return try await body(prepare(base))
        }
    }

    private func chunkURL(_ root: URL, hex: String) -> URL {
        root.appending(path: "chunks/\(hex.prefix(2))/\(hex)")
    }

    private func storeChunk(_ root: URL, hex: String, data: Data) throws {
        let url = chunkURL(root, hex: hex)
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(DataBlob.encode(data), to: url)
    }

    private func loadChunk(_ root: URL, hex: String) throws -> Data {
        let data = try DataBlob.decode(Data(contentsOf: chunkURL(root, hex: hex)))
        guard sha256(data).hex == hex else { throw ProxmacsError("Chunk \(hex) is corrupt (digest mismatch)") }
        return data
    }

    private func isZero(_ hex: String, length: Int) -> Bool {
        hex == (length == ImageChunker.chunkSize ? ImageChunker.zeroChunkDigest : sha256(Data(count: length))).hex
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appending(path: ".tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        do {
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            // Another writer stored the same content-addressed chunk first: fine.
            if !FileManager.default.fileExists(atPath: url.path) { throw error }
        }
    }

    private func listManifests(_ root: URL, vm: String) throws -> [(id: String, manifest: Manifest)] {
        let dir = root.appending(path: "snapshots/\(vm)")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: dir.appending(path: "\(id)/manifest.json")),
                  let manifest = try? JSONDecoder.proxmacs.decode(Manifest.self, from: data) else { return nil }
            return (id, manifest)
        }.sorted { $0.manifest.time > $1.manifest.time }
    }

    private func latestManifest(_ root: URL, vm: String) throws -> Manifest? {
        try listManifests(root, vm: vm).first?.manifest
    }

    /// Deletes chunks not referenced by any remaining snapshot of any VM.
    private func collectGarbage(_ root: URL) throws {
        var referenced = Set<String>()
        let vms = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "snapshots").path)) ?? []
        for vm in vms where !vm.hasPrefix(".") {
            for entry in try listManifests(root, vm: vm) {
                referenced.formUnion(entry.manifest.images.flatMap(\.chunks))
                referenced.formUnion(entry.manifest.files.values)
            }
        }
        let chunks = root.appending(path: "chunks")
        for prefix in (try? FileManager.default.contentsOfDirectory(atPath: chunks.path)) ?? [] {
            let dir = chunks.appending(path: prefix)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !referenced.contains(name) {
                try? FileManager.default.removeItem(at: dir.appending(path: name))
            }
        }
    }
}
