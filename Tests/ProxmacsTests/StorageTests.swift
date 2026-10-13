import XCTest
@testable import Proxmacs

final class StorageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "proxmacs-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSparseCopyKeepsHolesAndData() throws {
        let source = dir.appending(path: "disk.img")
        let size: off_t = 256 << 20
        let fd = open(source.path, O_WRONLY | O_CREAT, 0o644)
        XCTAssertEqual(ftruncate(fd, size), 0)
        // Data at the start, in the middle and in the last (partial) chunk; holes in between.
        for (offset, byte) in [(off_t(0), UInt8(1)), (off_t(100 << 20), 2), (size - 4096, 3)] {
            let block = [UInt8](repeating: byte, count: 4096)
            XCTAssertEqual(pwrite(fd, block, block.count, offset), 4096)
        }
        close(fd)

        let copy = dir.appending(path: "copy.img")
        var reported: Int64 = 0
        try FileCopy.sparseCopy(source, to: copy) { reported += $0 }

        XCTAssertEqual(reported, Int64(size))
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: copy))
        let allocated = try copy.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? .max
        XCTAssertLessThan(allocated, 16 << 20, "holes must stay holes")
    }

    func testCopyTreeAndMoveWithinVolume() throws {
        let tree = dir.appending(path: "vm")
        try FileManager.default.createDirectory(at: tree.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("config".utf8).write(to: tree.appending(path: "config.json"))
        try Data("nested".utf8).write(to: tree.appending(path: "sub/file"))

        try FileCopy.copyTree(tree, to: dir.appending(path: "vm-copy"))
        XCTAssertEqual(try String(contentsOf: dir.appending(path: "vm-copy/sub/file"), encoding: .utf8), "nested")

        try FileCopy.move(tree, to: dir.appending(path: "vm-moved"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(try String(contentsOf: dir.appending(path: "vm-moved/config.json"), encoding: .utf8), "config")
    }

    func testValidateAcceptsNewEmptyOrMatchingFolders() throws {
        let fresh = dir.appending(path: "new/VMs")
        XCTAssertEqual(try Storage.validate(fresh.path, for: .vms), Storage.canonical(fresh))

        let prepared = dir.appending(path: "Backups")
        try Storage.prepare(prepared, for: .backups)
        XCTAssertEqual(Storage.markerKind(prepared), .backups)
        XCTAssertNoThrow(try Storage.validate(prepared.path, for: .backups))
        XCTAssertThrowsError(try Storage.validate(prepared.path, for: .vms))
    }

    func testValidateRejectsUnsuitableFolders() throws {
        let busy = dir.appending(path: "busy")
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try Data().write(to: busy.appending(path: "something"))
        XCTAssertThrowsError(try Storage.validate(busy.path, for: .vms))
        XCTAssertThrowsError(try Storage.validate("relative/path", for: .vms))
        XCTAssertThrowsError(try Storage.validate("/", for: .backups))
        XCTAssertThrowsError(try Storage.validate(Paths.support.appending(path: "x").path, for: .backups))
    }

    func testCanonicalResolvesSymlinkedParents() {
        // /tmp is a symlink to /private/tmp.
        XCTAssertEqual(Storage.canonical(path: "/tmp/proxmacs-not-there/x").path, "/private/tmp/proxmacs-not-there/x")
    }
}
