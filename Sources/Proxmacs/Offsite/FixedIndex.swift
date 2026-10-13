import Foundation

/// PBS fixed index (.fidx): 4096-byte header (little-endian) followed by 32-byte chunk digests.
struct FixedIndex {
    static let magic: [UInt8] = [47, 127, 65, 237, 145, 253, 15, 205]
    static let headerSize = 4096

    var size: UInt64
    var chunkSize: UInt64
    var digests: [Digest32]

    /// SHA-256 over the concatenated digests (PBS "index csum" for fixed indexes).
    var csum: Digest32 { Self.csum(digests) }

    static func csum(_ digests: [Digest32]) -> Digest32 {
        var data = Data(capacity: digests.count * 32)
        for digest in digests { data.append(contentsOf: digest) }
        return sha256(data)
    }

    init(size: UInt64, chunkSize: UInt64, digests: [Digest32]) {
        self.size = size
        self.chunkSize = chunkSize
        self.digests = digests
    }

    init(parsing data: Data) throws {
        guard data.count >= Self.headerSize, [UInt8](data.prefix(8)) == Self.magic else {
            throw ProxmacsError("not a PBS fixed index")
        }
        func u64(_ offset: Int) -> UInt64 {
            data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
        size = u64(64)
        chunkSize = u64(72)
        guard chunkSize > 0 else { throw ProxmacsError("fixed index has zero chunk size") }
        let count = Int((size + chunkSize - 1) / chunkSize)
        guard data.count >= Self.headerSize + count * 32 else { throw ProxmacsError("fixed index truncated") }
        digests = (0..<count).map { i in
            let start = data.startIndex + Self.headerSize + i * 32
            return [UInt8](data[start..<(start + 32)])
        }
    }
}
