import XCTest
@testable import Proxmacs

final class CloudInitSeedTests: XCTestCase {
    func testUserDataQuotesValues() {
        let yaml = CloudInitSeed.userData(hostname: "vm1", password: "p\"a: ss", sshKeys: ["ssh-ed25519 AAAA test@host"])
        XCTAssertTrue(yaml.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(yaml.contains(#"hostname: "vm1""#))
        XCTAssertTrue(yaml.contains(#"password: "p\"a: ss""#))
        XCTAssertTrue(yaml.contains(#"  - "ssh-ed25519 AAAA test@host""#))
        XCTAssertTrue(yaml.contains("User=root"))
    }

    func testBuildsSeedISOWithCidataLabel() async throws {
        let name = "proxmacs-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(at: Paths.vmDir(name)) }

        let deb = FileManager.default.temporaryDirectory.appending(path: "\(name).deb")
        try Data("fake".utf8).write(to: deb)
        defer { try? FileManager.default.removeItem(at: deb) }

        try await CloudInitSeed.build(name: name, password: nil, agentDeb: deb)
        let iso = Paths.seedISO(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: iso.path))

        // Mount it the way the guest will see it and check names survived (Joliet keeps "meta-data").
        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "\(name)-mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        try await Shell.check("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path, iso.path])
        defer { _ = try? Shell.runSync("/usr/bin/hdiutil", ["detach", mountPoint.path]) }

        let files = Set(try FileManager.default.contentsOfDirectory(atPath: mountPoint.path))
        XCTAssertTrue(files.isSuperset(of: ["meta-data", "user-data", "network-config", "tart-guest-agent.deb"]), "got \(files)")
        let meta = try String(contentsOf: mountPoint.appending(path: "meta-data"), encoding: .utf8)
        XCTAssertTrue(meta.contains("local-hostname: \(name)"))
    }
}

extension Shell {
    /// Synchronous helper for test teardown.
    static func runSync(_ executable: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        try p.run()
        p.waitUntilExit()
    }
}
