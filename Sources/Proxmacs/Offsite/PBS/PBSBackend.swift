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

            // Downloading the previous index registers its chunks as known on the server, so they can
            // be appended without re-uploading (PBS incremental backup).
            var known = Set<String>()
            let previous = try await session.send(.GET, "/previous", query: [("archive-name", Self.diskArchive)])
            if previous.status == 200, let index = try? FixedIndex(parsing: previous.body) {
                known = Set(index.digests.map(\.hex))
            }

            let chunker = try ImageChunker(url: backupDir.appending(path: BackupFiles.disk))
            guard let wid = try await session.json(.POST, "/fixed_index",
                                                   query: [("archive-name", Self.diskArchive), ("size", String(chunker.size))]) as? Int else {
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
                progress(Double(index + 1) / Double(max(chunker.chunkCount, 1)))
            }
            if !batch.isEmpty { try await flush() }

            let csum = FixedIndex.csum(digests).hex
            try await session.json(.POST, "/fixed_close", query: [
                ("wid", String(wid)), ("chunk-count", String(digests.count)),
                ("size", String(chunker.size)), ("csum", csum),
            ])
            files.append(["filename": Self.diskArchive, "crypt-mode": "none", "size": chunker.size, "csum": csum])

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

    func snapshots(vm: String) async throws -> [RemoteSnapshot] {
        var query = namespaceQuery
        query += [("backup-type", "vm"), ("backup-id", vm)]
        let list = try await rest.get("/api2/json/admin/datastore/\(settings.datastore)/snapshots", query: query) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let time = (item["backup-time"] as? NSNumber)?.intValue else { return nil }
            return RemoteSnapshot(vm: vm, time: Date(timeIntervalSince1970: TimeInterval(time)), id: String(time))
        }.sorted { $0.time > $1.time }
    }

    func pull(_ snapshot: RemoteSnapshot, into dir: URL, progress: ProgressHandler) async throws {
        guard let time = Int(snapshot.id) else { throw ProxmacsError("bad snapshot id \(snapshot.id)") }
        let session = try await PBSH2Session.open(settings, secret: secret, protocolName: PBSH2Session.readerProtocol,
                                                  path: "/api2/json/reader", query: sessionQuery(vm: snapshot.vm, time: time))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifestData = try await DataBlob.decode(session.download("/download", query: [("file-name", Self.manifestBlob)]))
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] ?? [:]
            let archives = Set((manifest["files"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String })

            let index = try await FixedIndex(parsing: session.download("/download", query: [("file-name", Self.diskArchive)]))
            let writer = try SparseImageWriter(url: dir.appending(path: BackupFiles.disk), size: index.size)
            let chunkSize = index.chunkSize

            let work = index.digests.enumerated().compactMap { i, digest -> (Int, Digest32)? in
                let length = Int(min(chunkSize, index.size - UInt64(i) * chunkSize))
                let zero = length == ImageChunker.chunkSize ? ImageChunker.zeroChunkDigest : sha256(Data(count: length))
                return digest == zero ? nil : (i, digest)  // zero chunks stay holes
            }
            var done = 0
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
                for _ in 0..<Self.uploadConcurrency where addNext() {}
                while let (i, data) = try await group.next() {
                    try writer.write(data, at: UInt64(i) * chunkSize)
                    done += 1
                    progress(Double(done) / Double(max(work.count, 1)))
                    _ = addNext()
                }
            }
            try writer.finish()

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
