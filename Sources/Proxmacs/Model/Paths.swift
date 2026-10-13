import Foundation

/// Filesystem layout. Proxmacs owns everything under `support`; Tart owns `tartHome`.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// `PROXMACS_SUPPORT_DIR` overrides the data directory (development/testing).
    static let support: URL = {
        if let custom = ProcessInfo.processInfo.environment["PROXMACS_SUPPORT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home.appending(path: "Library/Application Support/Proxmacs", directoryHint: .isDirectory)
    }()
    static let images = support.appending(path: "images", directoryHint: .isDirectory)
    static let vms = support.appending(path: "vms", directoryHint: .isDirectory)
    static let backups = support.appending(path: "backups", directoryHint: .isDirectory)

    static let launchAgents = home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)

    static var tartHome: URL {
        if let custom = ProcessInfo.processInfo.environment["TART_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home.appending(path: ".tart", directoryHint: .isDirectory)
    }

    static func vmDir(_ name: String) -> URL { vms.appending(path: name, directoryHint: .isDirectory) }
    static func metaFile(_ name: String) -> URL { vmDir(name).appending(path: "meta.json") }
    static func seedISO(_ name: String) -> URL { vmDir(name).appending(path: "seed.iso") }
    static func runLog(_ name: String) -> URL { vmDir(name).appending(path: "run.log") }

    static func backupsDir(_ name: String) -> URL { backups.appending(path: name, directoryHint: .isDirectory) }

    static func tartVMDir(_ name: String) -> URL {
        tartHome.appending(path: "vms/\(name)", directoryHint: .isDirectory)
    }

    static func ensure() {
        for dir in [support, images, vms, backups, launchAgents] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
