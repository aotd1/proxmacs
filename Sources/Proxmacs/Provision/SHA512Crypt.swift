import CryptoKit
import Foundation

/// glibc-compatible SHA-512 crypt (`$6$`), so guest passwords are stored and seeded only as hashes.
/// macOS's crypt(3) only implements DES, hence this implementation of Drepper's specification.
enum SHA512Crypt {
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    static let defaultRounds = 5000

    /// Hash with a random 16-character salt.
    static func hash(_ password: String, rounds: Int = 100_000) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let salt = String(decoding: bytes.map { alphabet[Int($0) & 0x3F] }, as: UTF8.self)
        return hash(password, salt: salt, rounds: rounds)
    }

    static func hash(_ password: String, salt: String, rounds: Int = defaultRounds) -> String {
        let p = Array(password.utf8)
        let s = Array(salt.utf8.prefix(16))
        let rounds = min(max(rounds, 1000), 999_999_999)

        let b = digest(p, s, p)

        var a = SHA512()
        a.update(data: p)
        a.update(data: s)
        a.update(data: repeated(b, count: p.count))
        var length = p.count
        while length > 0 {
            a.update(data: length & 1 == 1 ? b : p)
            length >>= 1
        }
        var c = Array(a.finalize())

        let pSequence = repeated(digest(Array(repeating: p, count: p.count).flatMap { $0 }), count: p.count)
        let sSequence = repeated(digest(Array(repeating: s, count: 16 + Int(c[0])).flatMap { $0 }), count: s.count)

        for i in 0..<rounds {
            var ctx = SHA512()
            ctx.update(data: i & 1 == 1 ? pSequence : c)
            if i % 3 != 0 { ctx.update(data: sSequence) }
            if i % 7 != 0 { ctx.update(data: pSequence) }
            ctx.update(data: i & 1 == 1 ? c : pSequence)
            c = Array(ctx.finalize())
        }

        var out = "$6$"
        if rounds != defaultRounds { out += "rounds=\(rounds)$" }
        out += String(decoding: s, as: UTF8.self) + "$"
        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
            (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
            (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]
        var encoded: [UInt8] = []
        for (x, y, z) in order { encode(c[x], c[y], c[z], 4, into: &encoded) }
        encode(0, 0, c[63], 2, into: &encoded)
        return out + String(decoding: encoded, as: UTF8.self)
    }

    private static func digest(_ parts: [UInt8]...) -> [UInt8] {
        var ctx = SHA512()
        for part in parts { ctx.update(data: part) }
        return Array(ctx.finalize())
    }

    /// `source` repeated to exactly `count` bytes.
    private static func repeated(_ source: [UInt8], count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count { out += source.prefix(count - out.count) }
        return out
    }

    private static func encode(_ b2: UInt8, _ b1: UInt8, _ b0: UInt8, _ n: Int, into out: inout [UInt8]) {
        var w = (UInt32(b2) << 16) | (UInt32(b1) << 8) | UInt32(b0)
        for _ in 0..<n {
            out.append(alphabet[Int(w & 0x3F)])
            w >>= 6
        }
    }
}
