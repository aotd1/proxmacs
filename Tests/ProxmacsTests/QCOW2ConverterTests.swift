import XCTest
@testable import Proxmacs

final class QCOW2ConverterTests: XCTestCase {
    /// Any Debian genericcloud qcow2 works; architecture doesn't matter for the converter.
    private var sample: URL {
        if let path = ProcessInfo.processInfo.environment["PROXMACS_SAMPLE_QCOW2"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Proxmacs/images/debian-13-genericcloud-arm64.qcow2")
    }

    func testConvertsDebianCloudImage() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sample.path), "sample qcow2 not found at \(sample.path)")
        XCTAssertTrue(QCOW2Converter.isQCOW2(sample))

        let out = FileManager.default.temporaryDirectory.appending(path: "proxmacs-test-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: out) }

        try QCOW2Converter.convert(source: sample, destination: out)

        var st = stat()
        XCTAssertEqual(stat(out.path, &st), 0)
        XCTAssertEqual(st.st_size, 3 * 1024 * 1024 * 1024, "virtual size")
        XCTAssertLessThan(Int64(st.st_blocks) * 512, Int64(st.st_size) / 2, "output should be sparse")

        let handle = try FileHandle(forReadingFrom: out)
        defer { try? handle.close() }
        func read(_ count: Int, at offset: UInt64) throws -> Data {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
        func le<T: FixedWidthInteger>(_ data: Data, _ offset: Int, _: T.Type) -> T {
            data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }

        // GPT header at LBA 1.
        let gpt = try read(92, at: 512)
        XCTAssertEqual(String(decoding: gpt.prefix(8), as: UTF8.self), "EFI PART")
        let entriesLBA = le(gpt, 72, UInt64.self)
        let entryCount = Int(le(gpt, 80, UInt32.self))
        let entrySize = Int(le(gpt, 84, UInt32.self))
        let entries = try read(entryCount * entrySize, at: entriesLBA * 512)

        // At least one partition must carry an ext4 superblock (magic 0xEF53 at +1080).
        var ext4Partitions = 0
        for i in 0..<entryCount {
            let entry = entries.subdata(in: (i * entrySize)..<((i + 1) * entrySize))
            if entry.prefix(16).allSatisfy({ $0 == 0 }) { continue }
            let firstLBA = le(entry, 32, UInt64.self)
            let magic = try read(2, at: firstLBA * 512 + 1080)
            if magic.count == 2, le(magic, 0, UInt16.self) == 0xEF53 { ext4Partitions += 1 }
        }
        XCTAssertGreaterThanOrEqual(ext4Partitions, 1, "expected an ext4 root partition")
    }

    func testRejectsNonQCOW2() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "proxmacs-not-qcow2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: 4096).write(to: file)
        XCTAssertFalse(QCOW2Converter.isQCOW2(file))
        XCTAssertThrowsError(try QCOW2Converter.convert(source: file, destination: file.appendingPathExtension("raw")))
    }
}
