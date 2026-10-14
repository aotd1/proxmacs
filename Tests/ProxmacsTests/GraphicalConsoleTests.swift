import XCTest
@testable import Proxmacs

final class GraphicalConsoleTests: XCTestCase {
    func testConsoleRequiresExactOrigin() {
        XCTAssertTrue(GraphicalConsole.sameOrigin("https://console.example:8006", authority: "console.example:8006", tls: true))
        XCTAssertTrue(GraphicalConsole.sameOrigin("https://console.example", authority: "console.example:443", tls: true))
        for origin in [nil, "null", "https://evil.example", "http://console.example:8006", "https://console.example", "https://console.example:8006/path", "https://user@console.example:8006"] {
            XCTAssertFalse(GraphicalConsole.sameOrigin(origin, authority: "console.example:8006", tls: true))
        }
    }
}
