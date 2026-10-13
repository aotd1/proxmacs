import XCTest
@testable import Proxmacs

final class CloudInitSeedTests: XCTestCase {
    func testUserDataQuotesValues() {
        let config = CloudInitConfig(user: "alice", passwordHash: "$6$salt$hash", sshKeys: ["ssh-ed25519 AAAA/b+ test@host"])
        let yaml = CloudInitSeed.userData(hostname: "vm1", config: config)
        XCTAssertTrue(yaml.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(yaml.contains(#"hostname: "vm1""#))
        XCTAssertTrue(yaml.contains(#"  - name: "alice""#))
        XCTAssertTrue(yaml.contains(#"      - "ssh-ed25519 AAAA/b+ test@host""#), "slashes must not be escaped")
        XCTAssertTrue(yaml.contains(#"content: "ssh-ed25519 AAAA/b+ test@host\n""#))
        XCTAssertTrue(yaml.contains("ssh_deletekeys: false"))
        XCTAssertTrue(yaml.contains("User=root"))
        XCTAssertTrue(yaml.contains("      usermod -p '$6$salt$hash' \"$user\""))
        XCTAssertFalse(yaml.contains("passwd -l"))
    }

    func testPasswordStates() {
        XCTAssertTrue(CloudInitSeed.provisionScript(CloudInitConfig()).contains("passwd -l \"$user\""))
        let legacy = CloudInitConfig(managePassword: false)
        XCTAssertFalse(CloudInitSeed.provisionScript(legacy).contains("passwd -l"))
        XCTAssertFalse(CloudInitSeed.provisionScript(legacy).contains("usermod -p"))
    }

    func testNetworkConfig() {
        XCTAssertTrue(CloudInitSeed.networkConfig(GuestNetwork()).contains("dhcp-identifier: mac"))
        let yaml = CloudInitSeed.networkConfig(GuestNetwork(dhcp: false, address: "192.168.20.50/24", gateway: "192.168.20.1", dns: ["1.1.1.1", "9.9.9.9"]))
        XCTAssertTrue(yaml.contains("dhcp4: false"))
        XCTAssertTrue(yaml.contains(#"addresses: ["192.168.20.50/24"]"#))
        XCTAssertTrue(yaml.contains(#"        via: "192.168.20.1""#))
        XCTAssertTrue(yaml.contains(#"      addresses: ["1.1.1.1", "9.9.9.9"]"#))
    }

    func testValidation() {
        XCTAssertNoThrow(try CloudInitConfig(sshKeys: ["ssh-ed25519 AAAAC3Nza me@mac"]).validate())
        XCTAssertThrowsError(try CloudInitConfig(user: "root").validate())
        XCTAssertThrowsError(try CloudInitConfig(user: "Bad User").validate())
        XCTAssertThrowsError(try CloudInitConfig(sshKeys: ["ssh-ed25519 AAAA\ninjected: true"]).validate())
        XCTAssertThrowsError(try CloudInitConfig(passwordHash: "$6$x$y'; rm -rf /").validate())
        XCTAssertNoThrow(try CloudInitConfig(network: GuestNetwork(dhcp: false, address: "10.0.0.5/8", gateway: "10.1.2.3")).validate())
        XCTAssertThrowsError(try CloudInitConfig(network: GuestNetwork(dhcp: false, address: "10.0.0.5")).validate())
        XCTAssertThrowsError(try CloudInitConfig(network: GuestNetwork(dhcp: false, address: "10.0.0.5/24", gateway: "10.0.1.1")).validate())
        XCTAssertThrowsError(try CloudInitConfig(network: GuestNetwork(dhcp: false, address: "10.0.0.5/24", dns: ["dns.google"])).validate())
    }

    func testSHA512CryptVectors() {
        // From Drepper's specification (and `openssl passwd -6`).
        XCTAssertEqual(SHA512Crypt.hash("Hello world!", salt: "saltstring"),
                       "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1")
        XCTAssertEqual(SHA512Crypt.hash("Hello world!", salt: "saltstringsaltstring", rounds: 10000),
                       "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.")
        let random = SHA512Crypt.hash("pw")
        XCTAssertTrue(random.hasPrefix("$6$rounds=100000$"))
        XCTAssertNoThrow(try CloudInitConfig(passwordHash: random).validate())
    }

    func testBuildsSeedISOWithCidataLabel() async throws {
        let name = "proxmacs-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { try? FileManager.default.removeItem(at: Paths.vmDir(name)) }

        let deb = FileManager.default.temporaryDirectory.appending(path: "\(name).deb")
        try Data("fake".utf8).write(to: deb)
        defer { try? FileManager.default.removeItem(at: deb) }

        try await CloudInitSeed.build(name: name, config: CloudInitConfig(), agentDeb: deb)
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
