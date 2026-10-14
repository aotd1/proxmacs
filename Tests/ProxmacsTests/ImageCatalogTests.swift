import XCTest
@testable import Proxmacs

final class ImageCatalogTests: XCTestCase {
    func testIDsAreUniqueAndKeepTheDebianCache() {
        XCTAssertEqual(Set(ImageCatalog.all.map(\.id)).count, ImageCatalog.all.count)
        // Caches made before the catalog existed stay valid.
        XCTAssertEqual(ImageCatalog.find("debian13")?.raw.lastPathComponent, "debian-13-arm64.raw")
        XCTAssertNotNil(ImageCatalog.find(ImageCatalog.defaultID))
        for image in ImageCatalog.all {
            XCTAssertNoThrow(try CloudInitConfig(user: image.user).validate(), image.id)
        }
    }

    func testIndexSourcePicksNewestRelease() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "proxmacs-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let listing = dir.appending(path: "index.html")
        try """
        <a href="Fedora-Cloud-Base-Generic-44-1.6.aarch64.qcow2">x</a>
        <a href="Fedora-Cloud-Base-Generic-44-1.10.aarch64.qcow2">x</a>
        <a href="Fedora-Cloud-Base-Generic-44-20260424.n.0.aarch64.qcow2">nightly</a>
        <a href="Fedora-Cloud-Base-UEFI-UKI-44-1.11.aarch64.qcow2">uki</a>
        """.write(to: listing, atomically: true, encoding: .utf8)

        var image = ImageCatalog.find("fedora-44")!
        guard case .index(_, let pattern) = image.source else { return XCTFail("fedora-44 should be an index source") }
        image.source = .index(listing, pattern: pattern)
        let url = try await ImageStore.resolve(image)
        XCTAssertEqual(url.lastPathComponent, "Fedora-Cloud-Base-Generic-44-1.10.aarch64.qcow2")
    }
}
