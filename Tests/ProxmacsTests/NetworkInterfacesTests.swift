import XCTest
@testable import Proxmacs

final class NetworkInterfacesTests: XCTestCase {
    func testListeningAddressesFollowTheBind() {
        let any = NetworkInterfaces.listening(on: "0.0.0.0")
        XCTAssertTrue(any.contains { $0.address == "127.0.0.1" && $0.device.hasPrefix("lo") })
        XCTAssertFalse(any.contains(where: \.ipv6))
        XCTAssertFalse(NetworkInterfaces.listening(on: "::").contains { $0.address.lowercased().hasPrefix("fe80:") })
        XCTAssertEqual(NetworkInterfaces.listening(on: "127.0.0.1").map(\.address), ["127.0.0.1"])
    }
}
