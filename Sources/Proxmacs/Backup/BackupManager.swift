import Foundation

struct BackupRecord: Codable, Hashable {
    var date: Date
    /// True when the guest filesystem was frozen during the snapshot (or the VM was stopped).
    var consistent: Bool
    var vmWasRunning: Bool
}

struct BackupInfo: Identifiable, Hashable {
    var url: URL
    var record: BackupRecord
    var id: String { url.path }
}

/// Backups are APFS clones of Tart's VM files: instant and copy-on-write, but on the same volume.
enum BackupManager {
    static let vmFiles = ["disk.img", "nvram.bin", "config.json"]
    private static let recordFile = "backup.json"

    static func list(_ vm: String) -> [BackupInfo] {
        let dir = Paths.backupsDir(vm)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            guard let data = try? Data(contentsOf: url.appending(path: recordFile)),
                  let record = try? JSONDecoder.proxmacs.decode(BackupRecord.self, from: data) else { return nil }
            return BackupInfo(url: url, record: record)
        }.sorted { $0.record.date > $1.record.date }
    }

    static func backup(_ vm: String, running: Bool, tart: Tart, keep: Int) async throws -> BackupInfo {
        let date = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let target = Paths.backupsDir(vm).appending(path: formatter.string(from: date), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // Freeze the root filesystem through the guest agent so the clone is filesystem-consistent.
        var frozen = false
        if running, (try? await tart.exec(vm, ["sync"]))?.succeeded == true {
            frozen = (try? await tart.exec(vm, ["fsfreeze", "--freeze", "/"]))?.succeeded == true
        }

        do {
            let source = Paths.tartVMDir(vm)
            for file in vmFiles {
                try clone(source.appending(path: file), to: target.appending(path: file))
            }
        } catch {
            if frozen { await thaw(vm, tart: tart) }
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        if frozen { await thaw(vm, tart: tart) }

        if FileManager.default.fileExists(atPath: Paths.metaFile(vm).path) {
            try? clone(Paths.metaFile(vm), to: target.appending(path: "meta.json"))
        }
        let record = BackupRecord(date: date, consistent: !running || frozen, vmWasRunning: running)
        try JSONEncoder.proxmacs.encode(record).write(to: target.appending(path: recordFile))

        prune(vm, keep: keep)
        return BackupInfo(url: target, record: record)
    }

    /// The VM must be stopped.
    static func restore(_ vm: String, from backup: BackupInfo, tart: Tart) async throws {
        try await tart.set(vm, disk: backup.url.appending(path: "disk.img"))
        let nvram = Paths.tartVMDir(vm).appending(path: "nvram.bin")
        try? FileManager.default.removeItem(at: nvram)
        try clone(backup.url.appending(path: "nvram.bin"), to: nvram)
    }

    static func delete(_ backup: BackupInfo) throws {
        try FileManager.default.removeItem(at: backup.url)
    }

    static func prune(_ vm: String, keep: Int) {
        for old in list(vm).dropFirst(max(keep, 1)) {
            try? delete(old)
        }
    }

    private static func thaw(_ vm: String, tart: Tart) async {
        // Never leave the guest frozen: retry a few times.
        for attempt in 0..<5 {
            if (try? await tart.exec(vm, ["fsfreeze", "--unfreeze", "/"], timeout: 15))?.succeeded == true { return }
            try? await Task.sleep(for: .seconds(Double(attempt + 1)))
        }
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) != 0 {
            let code = errno
            // Fall back to a regular copy across volumes.
            if code == EXDEV || code == ENOTSUP {
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: source.path])
            }
        }
    }
}
