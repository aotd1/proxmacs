import XCTest
@testable import Proxmacs

final class OffsiteTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appending(path: "proxmacs-offsite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: DataBlob

    func testDataBlobRoundTrip() throws {
        let compressible = Data(repeating: 0x41, count: 1 << 20)
        let blob = DataBlob.encode(compressible)
        XCTAssertEqual([UInt8](blob.prefix(8)), DataBlob.compressedMagic)
        XCTAssertLessThan(blob.count, compressible.count / 10)
        XCTAssertEqual(try DataBlob.decode(blob), compressible)

        var random = Data(count: 4096)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 4096, $0.baseAddress!) }
        let raw = DataBlob.encode(random)
        XCTAssertEqual([UInt8](raw.prefix(8)), DataBlob.uncompressedMagic, "incompressible data stays raw")
        XCTAssertEqual(try DataBlob.decode(raw), random)

        var corrupt = raw
        corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertThrowsError(try DataBlob.decode(corrupt))
    }

    func testCRCMatchesZlib() {
        // Standard CRC-32 (IEEE) check value, as used by PBS's crc32fast.
        XCTAssertEqual(DataBlob.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: Chunking

    func testChunkerDetectsHolesAndShortTail() throws {
        let url = tmp.appending(path: "sparse.img")
        let size = UInt64(3 * ImageChunker.chunkSize + 1000)
        let writer = try SparseImageWriter(url: url, size: size)
        try writer.write(Data(repeating: 7, count: 100), at: UInt64(ImageChunker.chunkSize) + 5)
        try writer.finish()

        let chunker = try ImageChunker(url: url)
        XCTAssertEqual(chunker.chunkCount, 4)
        let chunks = try (0..<4).map { try chunker.chunk(at: $0) }
        XCTAssertNil(chunks[0].data)
        XCTAssertEqual(chunks[0].digest, ImageChunker.zeroChunkDigest)
        XCTAssertNotNil(chunks[1].data)
        XCTAssertNil(chunks[2].data)
        XCTAssertEqual(chunks[3].length, 1000)
        XCTAssertEqual(chunks[3].digest, sha256(Data(count: 1000)))
    }

    func testFixedIndexParsing() throws {
        var data = Data(FixedIndex.magic)
        data.append(Data(count: 56))  // uuid + ctime + index_csum
        var size = UInt64(10 * 1024 * 1024).littleEndian
        var chunk = UInt64(4 * 1024 * 1024).littleEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &chunk) { data.append(contentsOf: $0) }
        data.append(Data(count: FixedIndex.headerSize - data.count))
        for i in 0..<3 { data.append(contentsOf: [UInt8](repeating: UInt8(i), count: 32)) }

        let index = try FixedIndex(parsing: data)
        XCTAssertEqual(index.size, 10 * 1024 * 1024)
        XCTAssertEqual(index.digests.count, 3)
        XCTAssertEqual(index.digests[2], [UInt8](repeating: 2, count: 32))
    }

    // MARK: Chunk store (SMB backend logic on a local directory)

    func testChunkStorePushIncrementalPullPrune() async throws {
        let store = ChunkStoreBackend(localRoot: tmp.appending(path: "share"))
        let chunk = ImageChunker.chunkSize

        // A 64 MiB sparse disk with data in chunks 0, 5 and 9.
        let backupA = try makeBackup("a", size: UInt64(16 * chunk), writes: [(0, 1), (5, 2), (9, 3)])
        let recordA = BackupRecord(date: Date(timeIntervalSince1970: 1_000_000), consistent: true, vmWasRunning: true)
        try await store.push(vm: "vm1", backupDir: backupA, record: recordA) { _ in }
        XCTAssertEqual(storedChunkCount(), 3 + 2, "3 data chunks + nvram + config; zero chunks are not stored")

        // Second backup: chunk 5 changed, everything else identical → exactly one new data chunk.
        let backupB = try makeBackup("b", size: UInt64(16 * chunk), writes: [(0, 1), (5, 99), (9, 3)])
        let recordB = BackupRecord(date: Date(timeIntervalSince1970: 2_000_000), consistent: false, vmWasRunning: true)
        try await store.push(vm: "vm1", backupDir: backupB, record: recordB) { _ in }
        XCTAssertEqual(storedChunkCount(), 6)

        let snapshots = try await store.snapshots(vm: "vm1")
        XCTAssertEqual(snapshots.map(\.id), ["2000000", "1000000"])

        let restored = tmp.appending(path: "restored", directoryHint: .isDirectory)
        try await store.pull(snapshots[0], into: restored) { _ in }
        XCTAssertEqual(try Data(contentsOf: restored.appending(path: "disk.img")), try Data(contentsOf: backupB.appending(path: "disk.img")))
        XCTAssertEqual(try Data(contentsOf: restored.appending(path: "nvram.bin")), try Data(contentsOf: backupB.appending(path: "nvram.bin")))
        var st = stat()
        stat(restored.appending(path: "disk.img").path, &st)
        XCTAssertLessThan(Int(st.st_blocks) * 512, 8 * chunk, "restored disk stays sparse")
        let record = try JSONDecoder.proxmacs.decode(BackupRecord.self, from: Data(contentsOf: restored.appending(path: "backup.json")))
        XCTAssertFalse(record.consistent)

        // Keep 1: snapshot A goes, and its unique chunk (old chunk 5) is garbage-collected.
        try await store.prune(vm: "vm1", keep: 1)
        let remaining = try await store.snapshots(vm: "vm1")
        XCTAssertEqual(remaining.map(\.id), ["2000000"])
        XCTAssertEqual(storedChunkCount(), 5)
    }

    func testChunkStoreExtraDisksAndVerify() async throws {
        let store = ChunkStoreBackend(localRoot: tmp.appending(path: "share"))
        let chunk = ImageChunker.chunkSize
        let backup = try makeBackup("x", size: UInt64(4 * chunk), writes: [(1, 5)])
        let extra = try SparseImageWriter(url: backup.appending(path: "disk1.img"), size: UInt64(8 * chunk))
        try extra.write(Data(repeating: 9, count: 4096), at: UInt64(6 * chunk))
        try extra.finish()
        let record = BackupRecord(date: Date(timeIntervalSince1970: 3_000_000), consistent: true, vmWasRunning: false)
        try await store.push(vm: "vm2", backupDir: backup, record: record) { _ in }

        let snapshot = try await store.snapshots(vm: "vm2")[0]
        let summary = try await store.verify(snapshot) { _ in }
        XCTAssertTrue(summary.hasPrefix("4 chunks"), summary)  // 2 data chunks + nvram + config

        let restored = tmp.appending(path: "restored2", directoryHint: .isDirectory)
        try await store.pull(snapshot, into: restored) { _ in }
        XCTAssertEqual(try Data(contentsOf: restored.appending(path: "disk1.img")), try Data(contentsOf: backup.appending(path: "disk1.img")))
        XCTAssertEqual(BackupFiles.images(in: restored), ["disk.img", "disk1.img"])

        // Corrupt the extra disk's data chunk: verify must notice.
        let digest = try ImageChunker(url: backup.appending(path: "disk1.img")).chunk(at: 6).digest.hex
        let file = tmp.appending(path: "share/proxmacs-store/chunks/\(digest.prefix(2))/\(digest)")
        try DataBlob.encode(Data(repeating: 1, count: 4096)).write(to: file)
        do {
            _ = try await store.verify(snapshot) { _ in }
            XCTFail("verify passed a corrupt chunk")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("corrupt"), error.localizedDescription)
        }
    }

    func testBackupStraightToTarget() async throws {
        // A stopped VM in a scratch Tart home: clone to staging, push, remove the staging copy.
        let home = tmp.appending(path: "tart", directoryHint: .isDirectory)
        setenv("TART_HOME", home.path, 1)
        defer { unsetenv("TART_HOME") }
        let vmDir = try makeBackup("tart/vms/direct-vm", size: UInt64(2 * ImageChunker.chunkSize), writes: [(1, 4)])
        let store = ChunkStoreBackend(localRoot: tmp.appending(path: "share"))

        let record = try await BackupManager.backup("direct-vm", running: false, tart: Tart(path: "/usr/bin/false"), to: store) { _ in }
        XCTAssertTrue(record.consistent)
        let snapshots = try await store.snapshots(vm: "direct-vm")
        XCTAssertEqual(snapshots.count, 1)
        let restored = tmp.appending(path: "restored3", directoryHint: .isDirectory)
        try await store.pull(snapshots[0], into: restored) { _ in }
        XCTAssertEqual(try Data(contentsOf: restored.appending(path: "disk.img")), try Data(contentsOf: vmDir.appending(path: "disk.img")))
        let staging = home.appending(path: ".proxmacs-staging")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty, "staging copy removed")
    }

    private func makeBackup(_ name: String, size: UInt64, writes: [(chunk: Int, byte: UInt8)]) throws -> URL {
        let dir = tmp.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try SparseImageWriter(url: dir.appending(path: "disk.img"), size: size)
        for write in writes {
            try writer.write(Data(repeating: write.byte, count: 4096), at: UInt64(write.chunk * ImageChunker.chunkSize))
        }
        try writer.finish()
        try Data(repeating: 0xAB, count: 128 * 1024).write(to: dir.appending(path: "nvram.bin"))
        try Data(#"{"cpuCount":2}"#.utf8).write(to: dir.appending(path: "config.json"))
        return dir
    }

    private func storedChunkCount() -> Int {
        let chunks = tmp.appending(path: "share/proxmacs-store/chunks")
        let prefixes = (try? FileManager.default.contentsOfDirectory(atPath: chunks.path)) ?? []
        return prefixes.reduce(0) { $0 + ((try? FileManager.default.contentsOfDirectory(atPath: chunks.appending(path: $1).path))?.count ?? 0) }
    }
}
