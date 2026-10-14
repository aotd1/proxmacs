import XCTest
@testable import Proxmacs

final class BackupRecordTests: XCTestCase {
    func testLegacyBackupDoesNotInventVirtualCapacity() throws {
        let data = Data(#"{"date":0,"consistent":true,"vmWasRunning":false}"#.utf8)
        let record = try JSONDecoder().decode(BackupRecord.self, from: data)
        XCTAssertNil(record.diskGB)
    }

    func testMacBackupPreservesCapacityAndOriginalState() throws {
        let record = BackupRecord(date: Date(), consistent: true, vmWasRunning: true, diskGB: 200)
        let decoded = try JSONDecoder().decode(BackupRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.diskGB, 200)
        XCTAssertTrue(decoded.vmWasRunning)
        XCTAssertTrue(decoded.consistent)
    }
}
