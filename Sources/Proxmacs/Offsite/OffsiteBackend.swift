import Foundation

struct RemoteSnapshot: Codable, Hashable, Identifiable {
    var vm: String
    var time: Date
    /// Backend-specific snapshot id (epoch seconds for both SMB and PBS).
    var id: String
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Files that make up a local backup (see BackupManager): the disk is chunked, the rest are small blobs.
enum BackupFiles {
    static let disk = "disk.img"
    static let blobs = ["nvram.bin", "config.json", "meta.json"]
}

protocol OffsiteBackend {
    /// Checks connectivity/credentials and returns a human-readable status line.
    func test() async throws -> String
    /// Uploads a local backup directory (disk.img + small files) as a snapshot of `vm`.
    func push(vm: String, backupDir: URL, record: BackupRecord, progress: ProgressHandler) async throws
    func snapshots(vm: String) async throws -> [RemoteSnapshot]
    /// Reconstructs a snapshot into `dir` (sparse disk.img + small files + backup.json).
    func pull(_ snapshot: RemoteSnapshot, into dir: URL, progress: ProgressHandler) async throws
    /// Keeps the newest `keep` snapshots of `vm`.
    func prune(vm: String, keep: Int) async throws
}

extension BackupRecord {
    /// Record for a backup reconstructed from an offsite snapshot.
    static func pulled(from snapshot: RemoteSnapshot, consistent: Bool, target: String) -> BackupRecord {
        BackupRecord(date: snapshot.time, consistent: consistent, vmWasRunning: false, source: target)
    }
}
