import Foundation
import NIOHTTP1

/// Native Proxmox Backup Server client. VMs are stored as backup-type `vm`, backup-id = VM name:
/// `disk.img.fidx` (4 MiB fixed chunks, zstd), `nvram.bin.blob`, `config.json.blob`, `meta.json.blob`.
struct PBSBackend: OffsiteBackend {
    let settings: PBSSettings
    let secret: String

    static let diskArchive = "disk.img.fidx"
    static let manifestBlob = "index.json.blob"
    private static let uploadConcurrency = 4
    private static let appendBatch = 128

    private var rest: PBSRest { PBSRest(settings: settings, secret: secret) }

    private func sessionQuery(vm: String, time: Int) -> [(String, String)] {
        var query = [("store", settings.datastore), ("backup-type", "vm"), ("backup-id", vm), ("backup-time", String(time))]
        if let ns = settings.namespace, !ns.isEmpty { query.append(("ns", ns)) }
        return query
    }

    // MARK: - OffsiteBackend

    func test() async throws -> String {
        let version = try await rest.get("/api2/json/version") as? [String: Any]
        let groups = try await rest.get("/api2/json/admin/datastore/\(settings.datastore)/groups", query: namespaceQuery) as? [Any]
        return "PBS \(version?["version"] as? String ?? "?"), datastore \(settings.datastore): \(groups?.count ?? 0) backup groups visible"
    }

    func push(vm: String, backupDir: URL, record: BackupRecord, progress: ProgressHandler) async throws {
        let time = Int(record.date.timeIntervalSince1970)
        let session = try await PBSH2Session.open(settings, secret: secret, protocolName: PBSH2Session.backupProtocol,
                                                  path: "/api2/json/backup", query: sessionQuery(vm: vm, time: time))
        do {
            var files: [[String: Any]] = []
            let images = try BackupFiles.images(in: backupDir).map { ($0, try ImageChunker(url: backupDir.appending(path: $0))) }
            let total = Double(max(images.reduce(0) { $0 + $1.1.chunkCount }, 1))
            var done = 0
            for (name, chunker) in images {
                files.append(try await upload(chunker, archive: "\(name).fidx", session: session) {
                    done += 1
                    progress(Double(done) / total)
                })
            }

            for name in BackupFiles.blobs {
                guard let data = try? Data(contentsOf: backupDir.appending(path: name)) else { continue }
                let blob = DataBlob.encode(data)
                let archive = "\(name).blob"
                try await session.json(.POST, "/blob", query: [("file-name", archive), ("encoded-size", String(blob.count))],
                                       body: blob, contentType: "application/octet-stream")
                files.append(["filename": archive, "crypt-mode": "none", "size": blob.count, "csum": sha256(blob).hex])
            }

            let manifest: [String: Any] = [
                "backup-type": "vm",
                "backup-id": vm,
                "backup-time": time,
                "files": files,
                "unprotected": ["proxmacs": ["consistent": record.consistent, "vmWasRunning": record.vmWasRunning]],
                "signature": NSNull(),
            ]
            let manifestBlob = DataBlob.encode(try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]))
            try await session.json(.POST, "/blob", query: [("file-name", Self.manifestBlob), ("encoded-size", String(manifestBlob.count))],
                                   body: manifestBlob, contentType: "application/octet-stream")
            try await session.json(.POST, "/finish")
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// Uploads one disk image as a fixed index archive; returns its manifest entry.
    private func upload(_ chunker: ImageChunker, archive: String, session: PBSH2Session, step: () -> Void) async throws -> [String: Any] {
        // Downloading the previous index registers its chunks as known on the server, so they can
        // be appended without re-uploading (PBS incremental backup).
        var known = Set<String>()
        let previous = try await session.send(.GET, "/previous", query: [("archive-name", archive)])
        if previous.status == 200, let index = try? FixedIndex(parsing: previous.body) {
            known = Set(index.digests.map(\.hex))
        }

        guard let wid = try await session.json(.POST, "/fixed_index",
                                               query: [("archive-name", archive), ("size", String(chunker.size))]) as? Int else {
            throw ProxmacsError("PBS did not return a writer id")
        }

        var digests: [Digest32] = []
        digests.reserveCapacity(chunker.chunkCount)
        var batch: [ImageChunk] = []

        func flush() async throws {
            // Upload unknown chunks (bounded concurrency), then append the whole batch to the index.
            let toUpload = batch.filter { !known.contains($0.digest.hex) }
            var seen = Set<String>()
            let unique = toUpload.filter { seen.insert($0.digest.hex).inserted }
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = unique.makeIterator()
                func addNext() -> Bool {
                    guard let chunk = iterator.next() else { return false }
                    group.addTask {
                        let raw = chunk.data ?? Data(count: chunk.length)
                        let blob = DataBlob.encode(raw)
                        try await session.json(.POST, "/fixed_chunk", query: [
                            ("wid", String(wid)), ("digest", chunk.digest.hex),
                            ("size", String(raw.count)), ("encoded-size", String(blob.count)),
                        ], body: blob, contentType: "application/octet-stream")
                    }
                    return true
                }
                for _ in 0..<Self.uploadConcurrency where addNext() {}
                while try await group.next() != nil { _ = addNext() }
            }
            for chunk in unique { known.insert(chunk.digest.hex) }

            let append: [String: Any] = [
                "wid": wid,
                "digest-list": batch.map(\.digest.hex),
                "offset-list": batch.map(\.offset),
            ]
            try await session.json(.PUT, "/fixed_index", body: JSONSerialization.data(withJSONObject: append),
                                   contentType: "application/json")
            batch.removeAll(keepingCapacity: true)
        }

        for index in 0..<chunker.chunkCount {
            try Task.checkCancellation()
            let chunk = try chunker.chunk(at: index)
            digests.append(chunk.digest)
            batch.append(chunk)
            if batch.count >= Self.appendBatch { try await flush() }
            step()
        }
        if !batch.isEmpty { try await flush() }

        let csum = FixedIndex.csum(digests).hex
        try await session.json(.POST, "/fixed_close", query: [
            ("wid", String(wid)), ("chunk-count", String(digests.count)),
            ("size", String(chunker.size)), ("csum", csum),
        ])
        return ["filename": archive, "crypt-mode": "none", "size": chunker.size, "csum": csum]
    }

    func snapshots(vm: String) async throws -> [RemoteSnapshot] {
        var query = namespaceQuery
        query += [("backup-type", "vm"), ("backup-id", vm)]
        let list = try await rest.get("/api2/json/admin/datastore/\(settings.datastore)/snapshots", query: query) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let time = (item["backup-time"] as? NSNumber)?.intValue else { return nil }
            return RemoteSnapshot(vm: vm, time: Date(timeIntervalSince1970: TimeInterval(time)), id: String(time))
        }.sorted { $0.time > $1.time }
    }

    /// Disk image archives in a snapshot manifest: disk.img.fidx and the extra disks' diskN.img.fidx.
    private static func imageArchives(_ manifest: [String: Any]) -> [String] {
        (manifest["files"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
            .filter { $0.hasSuffix(".fidx") && (String($0.dropLast(5)) == BackupFiles.disk || ExtraDisk.isValidFile(String($0.dropLast(5)))) }
            .sorted()
    }

    private func reader(_ snapshot: RemoteSnapshot) async throws -> PBSH2Session {
        guard let time = Int(snapshot.id) else { throw ProxmacsError("bad snapshot id \(snapshot.id)") }
        return try await PBSH2Session.open(settings, secret: secret, protocolName: PBSH2Session.readerProtocol,
                                           path: "/api2/json/reader", query: sessionQuery(vm: snapshot.vm, time: time))
    }

    /// Non-zero chunks of an index with their positions (zero chunks stay holes and are never stored).
    private static func dataChunks(_ index: FixedIndex) -> [(Int, Digest32)] {
        index.digests.enumerated().compactMap { i, digest -> (Int, Digest32)? in
            let length = Int(min(index.chunkSize, index.size - UInt64(i) * index.chunkSize))
            let zero = length == ImageChunker.chunkSize ? ImageChunker.zeroChunkDigest : sha256(Data(count: length))
            return digest == zero ? nil : (i, digest)
        }
    }

    /// Downloads chunks with bounded concurrency, checking each digest; `handle` gets them as they arrive.
    private static func fetch(_ work: [(Int, Digest32)], session: PBSH2Session, handle: (Int, Data) throws -> Void) async throws {
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var iterator = work.makeIterator()
            func addNext() -> Bool {
                guard let (i, digest) = iterator.next() else { return false }
                group.addTask {
                    let data = try await DataBlob.decode(session.download("/chunk", query: [("digest", digest.hex)]))
                    guard sha256(data) == digest else { throw ProxmacsError("chunk \(digest.hex) failed verification") }
                    return (i, data)
                }
                return true
            }
            for _ in 0..<uploadConcurrency where addNext() {}
            while let (i, data) = try await group.next() {
                try handle(i, data)
                _ = addNext()
            }
        }
    }

    func pull(_ snapshot: RemoteSnapshot, into dir: URL, progress: ProgressHandler) async throws {
        let session = try await reader(snapshot)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifestData = try await DataBlob.decode(session.download("/download", query: [("file-name", Self.manifestBlob)]))
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
            let archives = Set((manifest["files"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String })

            var indexes: [(String, FixedIndex)] = []
            for archive in Self.imageArchives(manifest) {
                indexes.append((String(archive.dropLast(5)), try await FixedIndex(parsing: session.download("/download", query: [("file-name", archive)]))))
            }
            let total = Double(max(indexes.reduce(0) { $0 + Self.dataChunks($1.1).count }, 1))
            var done = 0
            for (name, index) in indexes {
                let writer = try SparseImageWriter(url: dir.appending(path: name), size: index.size)
                try await Self.fetch(Self.dataChunks(index), session: session) { i, data in
                    try writer.write(data, at: UInt64(i) * index.chunkSize)
                    done += 1
                    progress(Double(done) / total)
                }
                try writer.finish()
            }

            for name in BackupFiles.blobs where archives.contains("\(name).blob") {
                let data = try await DataBlob.decode(session.download("/download", query: [("file-name", "\(name).blob")]))
                try data.write(to: dir.appending(path: name))
            }

            let info = (manifest["unprotected"] as? [String: Any])?["proxmacs"] as? [String: Any]
            let record = BackupRecord.pulled(from: snapshot, consistent: info?["consistent"] as? Bool ?? false,
                                             target: "pbs://\(settings.host)/\(settings.datastore)")
            try JSONEncoder.proxmacs.encode(record).write(to: dir.appending(path: "backup.json"))
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    func verify(_ snapshot: RemoteSnapshot, progress: ProgressHandler) async throws -> String {
        let session = try await reader(snapshot)
        do {
            let manifestData = try await DataBlob.decode(session.download("/download", query: [("file-name", Self.manifestBlob)]))
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
            var seen = Set<String>()
            var work: [(Int, Digest32)] = []
            for archive in Self.imageArchives(manifest) {
                let index = try await FixedIndex(parsing: session.download("/download", query: [("file-name", archive)]))
                work += Self.dataChunks(index).filter { seen.insert($0.1.hex).inserted }
            }
            for name in BackupFiles.blobs {
                let archive = "\(name).blob"
                guard (manifest["files"] as? [[String: Any]] ?? []).contains(where: { $0["filename"] as? String == archive }) else { continue }
                _ = try await DataBlob.decode(session.download("/download", query: [("file-name", archive)]))
            }
            var bytes = 0, done = 0
            try await Self.fetch(work, session: session) { _, data in
                bytes += data.count
                done += 1
                progress(Double(done) / Double(max(work.count, 1)))
            }
            await session.close()
            return "\(work.count) chunks (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))) verified"
        } catch {
            await session.close()
            throw error
        }
    }

    func prune(vm: String, keep: Int) async throws {
        var form = namespaceQuery
        form += [("backup-type", "vm"), ("backup-id", vm), ("keep-last", String(max(keep, 1)))]
        _ = try await rest.post("/api2/json/admin/datastore/\(settings.datastore)/prune", form: form)
    }

    private var namespaceQuery: [(String, String)] {
        if let ns = settings.namespace, !ns.isEmpty { return [("ns", ns)] }
        return []
    }
}
