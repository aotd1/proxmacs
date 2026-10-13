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

/// Guest IPv4 settings rendered into cloud-init's network-config.
struct GuestNetwork: Codable, Hashable {
    var dhcp = true
    /// CIDR, e.g. 192.168.20.50/24 (static only).
    var address: String?
    var gateway: String?
    var dns: [String] = []
}

/// What cloud-init provisions in the guest. Any change rebuilds the seed with a new instance-id,
/// so cloud-init applies it again on the VM's next start.
struct CloudInitConfig: Codable, Hashable {
    var user = "debian"
    /// SHA-512 crypt hash of the console password; nil = no password (account locked).
    var passwordHash: String?
    /// False for VMs created before Proxmacs tracked passwords: leave the guest's password alone
    /// until one is set or removed explicitly.
    var managePassword = true
    var sshKeys: [String] = []
    var network = GuestNetwork()

    init(user: String = "debian", passwordHash: String? = nil, managePassword: Bool = true, sshKeys: [String] = [], network: GuestNetwork = GuestNetwork()) {
        self.user = user
        self.passwordHash = passwordHash
        self.managePassword = managePassword
        self.sshKeys = sshKeys
        self.network = network
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? "debian"
        passwordHash = try c.decodeIfPresent(String.self, forKey: .passwordHash)
        managePassword = try c.decodeIfPresent(Bool.self, forKey: .managePassword) ?? true
        sshKeys = try c.decodeIfPresent([String].self, forKey: .sshKeys) ?? []
        network = try c.decodeIfPresent(GuestNetwork.self, forKey: .network) ?? GuestNetwork()
    }

    /// Settings of a VM created before cloud-init settings were stored: what its seed was built with.
    static var legacy: CloudInitConfig {
        CloudInitConfig(managePassword: false, sshKeys: legacyKeys)
    }
    /// Read once: `legacy` is evaluated on every UI refresh.
    private static let legacyKeys = CloudInitSeed.sshPublicKeys()

    /// A single-line OpenSSH public key of a type current OpenSSH accepts.
    static func isValidKey(_ key: String) -> Bool {
        key.range(of: #"^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+( [^\n\r]*)?$"#,
                  options: .regularExpression) != nil
    }

    func validate() throws {
        guard user.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil, user != "root" else {
            throw ProxmacsError("User must be a lowercase Linux user name (not root)")
        }
        for key in sshKeys where !Self.isValidKey(key) {
            throw ProxmacsError("Not an OpenSSH public key: \(key.prefix(40))…")
        }
        if let passwordHash, passwordHash.range(of: #"^\$6\$[./A-Za-z0-9$=]+$"#, options: .regularExpression) == nil {
            throw ProxmacsError("Invalid password hash")
        }
        guard !network.dhcp else { return }
        guard let address = network.address, let cidr = IPv4.parseCIDR(address), (1...32).contains(cidr.prefix) else {
            throw ProxmacsError("Static address must be in CIDR form, e.g. 192.168.1.50/24")
        }
        let (ip, prefix) = cidr
        if let gateway = network.gateway, !gateway.isEmpty {
            guard let gw = IPv4.parse(gateway) else { throw ProxmacsError("Invalid gateway \(gateway)") }
            guard IPv4.sameSubnet(ip, gw, prefix: prefix) else { throw ProxmacsError("Gateway \(gateway) is not in \(address)") }
        }
        for server in network.dns where IPv4.parse(server) == nil {
            throw ProxmacsError("Invalid DNS server \(server)")
        }
    }
}

enum IPv4 {
    static func parse(_ string: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    static func parseCIDR(_ string: String) -> (ip: UInt32, prefix: Int)? {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = parse(String(parts[0])), let prefix = Int(parts[1]) else { return nil }
        return (ip, prefix)
    }

    static func sameSubnet(_ a: UInt32, _ b: UInt32, prefix: Int) -> Bool {
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return a & mask == b & mask
    }
}

/// Proxmacs-side metadata for a VM. Tart's own config.json holds CPU/memory/MAC/disk.
struct VMMeta: Codable, Hashable {
    var name: String
    var network: NetworkMode
    var autostart: Bool
    var backup = BackupPolicy()
    var offsite = OffsitePolicy()
    var created = Date()
    /// nil for VMs created before these settings were stored (see `CloudInitConfig.legacy`).
    var cloudInit: CloudInitConfig?
    /// The seed changed while the VM was running; cleared when the VM next starts.
    var seedPending = false

    var effectiveCloudInit: CloudInitConfig { cloudInit ?? .legacy }

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
        cloudInit = try c.decodeIfPresent(CloudInitConfig.self, forKey: .cloudInit)
        seedPending = try c.decodeIfPresent(Bool.self, forKey: .seedPending) ?? false
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
