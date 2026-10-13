import Foundation

enum NetworkMode: Codable, Hashable {
    case nat
    case bridged(interface: String)

    var label: String {
        switch self {
        case .nat: "NAT"
        case .bridged(let iface): "bridged \(iface)"
        }
    }
}

struct BackupPolicy: Codable, Hashable {
    var daily = false
    var hour = 3
    var keep = 5
}

/// Proxmacs-side metadata for a VM. Tart's own config.json holds CPU/memory/MAC/disk.
struct VMMeta: Codable, Hashable {
    var name: String
    var network: NetworkMode
    var autostart: Bool
    var backup = BackupPolicy()
    var created = Date()

    static func load(_ name: String) -> VMMeta? {
        guard let data = try? Data(contentsOf: Paths.metaFile(name)) else { return nil }
        return try? JSONDecoder.proxmacs.decode(VMMeta.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Paths.vmDir(name), withIntermediateDirectories: true)
        try JSONEncoder.proxmacs.encode(self).write(to: Paths.metaFile(name), options: .atomic)
    }

    /// Names of all VMs that have Proxmacs metadata.
    static func allNames() -> [String] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: Paths.vms.path)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: Paths.metaFile($0).path) }.sorted()
    }
}

extension JSONEncoder {
    static let proxmacs: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let proxmacs: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
