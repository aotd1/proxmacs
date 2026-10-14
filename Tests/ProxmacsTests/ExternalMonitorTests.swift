import XCTest
@testable import Proxmacs

final class ExternalMonitorTests: XCTestCase {
    func testWaitingServiceIsNotRunningVM() {
        XCTAssertEqual(ExternalMonitor.state(serviceOutput: "\tstate = running\n", executable: "/bin/bash"), "stopped")
        XCTAssertEqual(ExternalMonitor.state(serviceOutput: "\tstate = running\n", executable: "/opt/virtual-machines/tart\n"), "running")
        XCTAssertEqual(ExternalMonitor.state(serviceOutput: "state = not running", executable: ""), "stopped")
        XCTAssertEqual(ExternalMonitor.state(serviceOutput: "state = running", executable: ""), "unknown")
    }
}
