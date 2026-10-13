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

struct OffsitePolicy: Codable, Hashable {
    /// Offsite target ids this VM is pushed to.
    var targets: [String] = []
    /// Push automatically after every local backup.
    var auto = false
}

/// Proxmacs-side metadata for a VM. Tart's own config.json holds CPU/memory/MAC/disk.
struct VMMeta: Codable, Hashable {
    var name: String
    var network: NetworkMode
    var autostart: Bool
    var backup = BackupPolicy()
    var offsite = OffsitePolicy()
    var created = Date()

    init(name: String, network: NetworkMode, autostart: Bool) {
        self.name = name
        self.network = network
        self.autostart = autostart
    }

    // Tolerate metadata written by older versions (missing keys fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        network = try c.decode(NetworkMode.self, forKey: .network)
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
        backup = try c.decodeIfPresent(BackupPolicy.self, forKey: .backup) ?? BackupPolicy()
        offsite = try c.decodeIfPresent(OffsitePolicy.self, forKey: .offsite) ?? OffsitePolicy()
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

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
