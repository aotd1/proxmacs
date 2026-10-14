import CryptoKit
import Foundation

/// A key for programs using the web API (`Authorization: Bearer pmx_…`). For now every key has the same
/// access as the admin password.
struct APIKey: Codable, Hashable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var name: String
    /// The key's first characters, to tell keys apart; the rest is never stored.
    var prefix: String
    /// SHA-256 of the whole key. Keys are 256 random bits, so a plain hash is enough (unlike passwords).
    var hash: String
    var created = Date()
}

/// API keys live in apikeys.json; when each was last used in apikeys-used.json. The second file is
/// written on every authenticated request, so it is kept apart: rewriting the key list there could
/// bring back a key revoked in the meantime.
struct APIKeyStore {
    static let shared = APIKeyStore(directory: Paths.support)
    static let tokenPrefix = "pmx_"

    let file: URL
    let usedFile: URL

    init(directory: URL) {
        file = directory.appending(path: "apikeys.json")
        usedFile = directory.appending(path: "apikeys-used.json")
    }

    func load() -> [APIKey] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder.proxmacs.decode([APIKey].self, from: data)) ?? []
    }

    /// Key id → last successful use.
    func lastUsed() -> [String: Date] {
        guard let data = try? Data(contentsOf: usedFile) else { return [:] }
        return (try? JSONDecoder.proxmacs.decode([String: Date].self, from: data)) ?? [:]
    }

    /// Creates a key and returns it with the full key, which is shown once and never stored.
    func create(name: String) throws -> (key: APIKey, secret: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProxmacsError("Name the key, e.g. after the script or host that uses it") }
        guard name.count <= 64 else { throw ProxmacsError("Use a name of up to 64 characters") }
        var keys = load()
        guard !keys.contains(where: { $0.name == name }) else { throw ProxmacsError("An API key named \(name) already exists") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ProxmacsError("Couldn't generate a random key")
        }
        let secret = Self.tokenPrefix + bytes.map { String(format: "%02x", $0) }.joined()
        let key = APIKey(name: name, prefix: String(secret.prefix(Self.tokenPrefix.count + 8)), hash: Self.digest(secret))
        keys.append(key)
        try write(keys, to: file)
        return (key, secret)
    }

    func remove(_ idOrName: String) throws {
        let keys = load()
        guard let key = keys.first(where: { $0.id == idOrName || $0.name == idOrName }) else {
            throw ProxmacsError("No API key named \(idOrName)")
        }
        try write(keys.filter { $0.id != key.id }, to: file)
        var used = lastUsed()
        if used.removeValue(forKey: key.id) != nil { try? write(used, to: usedFile) }
    }

    /// The key a bearer token belongs to, if any; records the use (at most once a minute per key).
    func authenticate(_ token: String) -> APIKey? {
        guard token.hasPrefix(Self.tokenPrefix) else { return nil }
        let hash = Self.digest(token)
        guard let key = load().first(where: { Self.equal($0.hash, hash) }) else { return nil }
        var used = lastUsed()
        if used[key.id].map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            used[key.id] = Date()
            try? write(used, to: usedFile)
        }
        return key
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let data = try JSONEncoder.proxmacs.encode(value)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
