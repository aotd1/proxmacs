import CryptoKit
import Foundation

typealias Digest32 = [UInt8]

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

func sha256(_ data: some DataProtocol) -> Digest32 { Array(SHA256.hash(data: data)) }

struct ImageChunk {
    var index: Int
    var offset: UInt64
    var length: Int
    /// nil when the whole chunk is zero (hole or zero bytes).
    var data: Data?
    var digest: Digest32
}

/// Splits a (sparse) disk image into PBS-style fixed 4 MiB chunks, identified by SHA-256 of the
/// plain data. Holes are detected with SEEK_DATA so unallocated regions are never read.
final class ImageChunker {
    static let chunkSize = 4 * 1024 * 1024
    static let zeroChunkDigest: Digest32 = sha256(Data(count: chunkSize))

    let size: UInt64
    var chunkCount: Int { Int((size + UInt64(Self.chunkSize) - 1) / UInt64(Self.chunkSize)) }

    private let fd: Int32
    private var buffer = [UInt8](repeating: 0, count: ImageChunker.chunkSize)

    init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path]) }
        var st = stat()
        fstat(fd, &st)
        size = UInt64(st.st_size)
    }

    deinit { close(fd) }

    func chunk(at index: Int) throws -> ImageChunk {
        let offset = UInt64(index) * UInt64(Self.chunkSize)
        let length = Int(min(UInt64(Self.chunkSize), size - offset))

        if isHole(offset: offset, length: length) {
            return ImageChunk(index: index, offset: offset, length: length, data: nil, digest: zeroDigest(length))
        }

        var total = 0
        while total < length {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + total, length - total, off_t(offset) + off_t(total)) }
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            total += n
        }
        if total < length { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress! + total, 0, length - total) } }

        if isAllZero(length) {
            return ImageChunk(index: index, offset: offset, length: length, data: nil, digest: zeroDigest(length))
        }
        let data = Data(buffer[0..<length])
        return ImageChunk(index: index, offset: offset, length: length, data: data, digest: sha256(data))
    }

    private func zeroDigest(_ length: Int) -> Digest32 {
        length == Self.chunkSize ? Self.zeroChunkDigest : sha256(Data(count: length))
    }

    private func isHole(offset: UInt64, length: Int) -> Bool {
        let next = lseek(fd, off_t(offset), SEEK_DATA)
        if next < 0 { return errno == ENXIO }  // no data after offset
        return UInt64(next) >= offset + UInt64(length)
    }

    private func isAllZero(_ length: Int) -> Bool {
        buffer.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            let words = length / 8
            for k in 0..<words where p.loadUnaligned(fromByteOffset: k * 8, as: UInt64.self) != 0 { return false }
            for k in (words * 8)..<length where raw[k] != 0 { return false }
            return true
        }
    }
}

/// Writes chunks back into a sparse image file (zero chunks become holes).
final class SparseImageWriter {
    private let fd: Int32

    init(url: URL, size: UInt64) throws {
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path]) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { close(fd) }

    func write(_ data: Data, at offset: UInt64) throws {
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func finish() throws {
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
