import CommonCrypto
import CryptoKit
import Foundation

struct WebSettings: Codable, Hashable {
    var enabled = true
    var port = 8006
    var bind = "0.0.0.0"
    /// Plain HTTP only makes sense on 127.0.0.1 or behind a TLS-terminating reverse proxy.
    var tls = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8006
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? "0.0.0.0"
        tls = try c.decodeIfPresent(Bool.self, forKey: .tls) ?? true
    }

    var scheme: String { tls ? "https" : "http" }

    static let file = Paths.support.appending(path: "web.json")

    static func load() -> WebSettings {
        guard let data = try? Data(contentsOf: file) else { return WebSettings() }
        return (try? JSONDecoder().decode(WebSettings.self, from: data)) ?? WebSettings()
    }

    func save() throws {
        try JSONEncoder.proxmacs.encode(self).write(to: Self.file, options: .atomic)
    }
}

/// Admin password (PBKDF2-SHA256, stored in secrets.json) and in-memory login sessions.
enum WebAuth {
    private static let secretKey = "web-admin-password"
    private static let iterations: UInt32 = 200_000

    static var hasPassword: Bool { Secrets.get(secretKey) != nil }

    static func setPassword(_ password: String) throws {
        guard password.count >= 8 else { throw ProxmacsError("Use at least 8 characters") }
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let hash = derive(password, salt: salt, iterations: iterations)
        try Secrets.set(secretKey, "pbkdf2-sha256$\(iterations)$\(Data(salt).base64EncodedString())$\(Data(hash).base64EncodedString())")
    }

    static func verify(_ password: String) -> Bool {
        guard let stored = Secrets.get(secretKey) else { return false }
        let parts = stored.split(separator: "$").map(String.init)
        guard parts.count == 4, parts[0] == "pbkdf2-sha256", let rounds = UInt32(parts[1]),
              let salt = Data(base64Encoded: parts[2]), let expected = Data(base64Encoded: parts[3]) else { return false }
        let actual = Data(derive(password, salt: [UInt8](salt), iterations: rounds))
        // Constant-time comparison.
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ password: String, salt: [UInt8], iterations: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        pw.withUnsafeBufferPointer { pwBuf in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwBuf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &out, out.count)
        }
        return out
    }
}

actor SessionStore {
    static let shared = SessionStore()
    static let cookieName = "pmx_session"
    static let lifetime: TimeInterval = 8 * 3600

    private var sessions: [String: Date] = [:]

    func create() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        sessions[token] = Date().addingTimeInterval(Self.lifetime)
        return token
    }

    func isValid(_ token: String?) -> Bool {
        guard let token, let expiry = sessions[token] else { return false }
        if expiry < Date() {
            sessions[token] = nil
            return false
        }
        sessions[token] = Date().addingTimeInterval(Self.lifetime)  // sliding expiry
        return true
    }

    func remove(_ token: String?) {
        if let token { sessions[token] = nil }
    }
}

/// Self-signed certificate for the web UI (generated once with the system LibreSSL).
enum WebCertificate {
    static let dir = Paths.support.appending(path: "web", directoryHint: .isDirectory)
    static let cert = dir.appending(path: "cert.pem")
    static let key = dir.appending(path: "key.pem")

    static func ensure() async throws {
        if FileManager.default.fileExists(atPath: cert.path), FileManager.default.fileExists(atPath: key.path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        try await Shell.check("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
            "-keyout", key.path, "-out", cert.path, "-days", "3650",
            "-subj", "/CN=\(host)/O=Proxmacs",
            "-addext", "subjectAltName=DNS:\(host),DNS:\(host).local,DNS:localhost,IP:127.0.0.1",
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    }

    /// SHA-256 fingerprint (aa:bb:…) to compare against the browser's certificate warning.
    static func fingerprint() -> String? {
        guard let pem = try? String(contentsOf: cert, encoding: .utf8) else { return nil }
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
