import Compression
import Foundation

enum QCOW2Error: LocalizedError {
    case notQCOW2
    case unsupported(String)
    case corrupt(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notQCOW2: "Not a qcow2 image"
        case .unsupported(let what): "Unsupported qcow2 image: \(what)"
        case .corrupt(let what): "Corrupt qcow2 image: \(what)"
        case .io(let what): "I/O error: \(what)"
        }
    }
}

/// Minimal qcow2 (v2/v3) → sparse raw converter. Handles standard, zero and zlib-compressed clusters;
/// rejects backing files, encryption, external data files, zstd and extended L2 entries.
enum QCOW2Converter {
    private static let magic: UInt32 = 0x5146_49FB  // "QFI\xfb"
    private static let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
    private static let compressedFlag: UInt64 = 1 << 62
    private static let zeroFlag: UInt64 = 1

    static func isQCOW2(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) } == magic
    }

    static func convert(source: URL, destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw QCOW2Error.io("open \(source.path): \(errnoString())") }
        defer { close(input) }

        let header = try readExact(input, count: 104, at: 0)
        guard be32(header, 0) == magic else { throw QCOW2Error.notQCOW2 }
        let version = be32(header, 4)
        guard version == 2 || version == 3 else { throw QCOW2Error.unsupported("version \(version)") }
        guard be64(header, 8) == 0 else { throw QCOW2Error.unsupported("backing file") }
        let clusterBits = Int(be32(header, 20))
        guard (9...21).contains(clusterBits) else { throw QCOW2Error.corrupt("cluster_bits \(clusterBits)") }
        let virtualSize = be64(header, 24)
        guard be32(header, 32) == 0 else { throw QCOW2Error.unsupported("encryption") }
        let l1Size = Int(be32(header, 36))
        let l1Offset = be64(header, 40)

        if version == 3 {
            let incompatible = be64(header, 72)
            // Bit 0 (dirty) only means refcounts may be stale; the mapping is still valid.
            if incompatible & (1 << 1) != 0 { throw QCOW2Error.corrupt("image marked corrupt") }
            if incompatible & (1 << 2) != 0 { throw QCOW2Error.unsupported("external data file") }
            if incompatible & (1 << 4) != 0 { throw QCOW2Error.unsupported("extended L2 entries") }
            if incompatible & ~UInt64(0b11111) != 0 { throw QCOW2Error.unsupported("incompatible features 0x\(String(incompatible, radix: 16))") }
            if incompatible & (1 << 3) != 0 {
                let headerLength = be32(header, 100)
                let ext = headerLength > 104 ? try readExact(input, count: 1, at: 104)[0] : 0
                if ext != 0 { throw QCOW2Error.unsupported("compression type \(ext) (only zlib)") }
            }
        }

        let clusterSize = 1 << clusterBits
        let l2Entries = clusterSize / 8
        let l1 = try readExact(input, count: l1Size * 8, at: l1Offset)

        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else { throw QCOW2Error.io("create \(destination.path): \(errnoString())") }
        defer { close(output) }
        guard ftruncate(output, off_t(virtualSize)) == 0 else { throw QCOW2Error.io("truncate: \(errnoString())") }

        // Compressed-cluster descriptor layout (qcow2 spec): host offset in bits 0..<x,
        // additional 512-byte sector count in bits x...61.
        let x = UInt64(62 - (clusterBits - 8))
        let hostOffsetMask = (UInt64(1) << x) - 1
        let sectorCountMask = (UInt64(1) << UInt64(clusterBits - 8)) - 1

        var cluster = [UInt8](repeating: 0, count: clusterSize)
        let bytesPerL1 = UInt64(l2Entries) * UInt64(clusterSize)

        for i in 0..<l1Size {
            progress?(min(1, Double(UInt64(i) * bytesPerL1) / Double(virtualSize)))
            let l2Offset = be64(l1, i * 8) & offsetMask
            if l2Offset == 0 { continue }
            let l2 = try readExact(input, count: clusterSize, at: l2Offset)

            for j in 0..<l2Entries {
                let guestOffset = UInt64(i) * bytesPerL1 + UInt64(j) * UInt64(clusterSize)
                if guestOffset >= virtualSize { break }
                let entry = be64(l2, j * 8)

                if entry & compressedFlag != 0 {
                    let hostOffset = entry & hostOffsetMask
                    let sectors = (entry >> x) & sectorCountMask
                    let compressedSize = Int((sectors + 1) * 512 - (hostOffset & 511))
                    let compressed = try readUpTo(input, count: compressedSize, at: hostOffset)
                    let decoded = cluster.withUnsafeMutableBytes { dst in
                        compressed.withUnsafeBytes { src in
                            // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what qcow2 stores.
                            compression_decode_buffer(
                                dst.baseAddress!.assumingMemoryBound(to: UInt8.self), clusterSize,
                                src.baseAddress!.assumingMemoryBound(to: UInt8.self), compressed.count,
                                nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard decoded > 0 else { throw QCOW2Error.corrupt("cannot inflate cluster at guest offset \(guestOffset)") }
                    if decoded < clusterSize { cluster.withUnsafeMutableBytes { _ = memset($0.baseAddress! + decoded, 0, clusterSize - decoded) } }
                } else {
                    if entry & zeroFlag != 0 { continue }
                    let hostOffset = entry & offsetMask
                    if hostOffset == 0 { continue }
                    let n = cluster.withUnsafeMutableBytes { pread(input, $0.baseAddress, clusterSize, off_t(hostOffset)) }
                    guard n >= 0 else { throw QCOW2Error.io("read: \(errnoString())") }
                    if n < clusterSize { cluster.withUnsafeMutableBytes { _ = memset($0.baseAddress! + n, 0, clusterSize - n) } }
                }

                let length = Int(min(UInt64(clusterSize), virtualSize - guestOffset))
                if isZero(cluster, length) { continue }
                let written = cluster.withUnsafeBytes { pwrite(output, $0.baseAddress, length, off_t(guestOffset)) }
                guard written == length else { throw QCOW2Error.io("write: \(errnoString())") }
            }
        }
        guard fsync(output) == 0 else { throw QCOW2Error.io("fsync: \(errnoString())") }
        progress?(1)
    }

    // MARK: - Helpers

    private static func readExact(_ fd: Int32, count: Int, at offset: UInt64) throws -> [UInt8] {
        let data = try readUpTo(fd, count: count, at: offset)
        guard data.count == count else { throw QCOW2Error.corrupt("short read at \(offset)") }
        return data
    }

    private static func readUpTo(_ fd: Int32, count: Int, at offset: UInt64) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + total, count - total, off_t(offset) + off_t(total)) }
            guard n >= 0 else { throw QCOW2Error.io("read: \(errnoString())") }
            if n == 0 { break }
            total += n
        }
        return Array(buffer.prefix(total))
    }

    private static func isZero(_ buffer: [UInt8], _ length: Int) -> Bool {
        buffer.withUnsafeBytes { raw in
            let words = length / 8
            let p = raw.baseAddress!
            for k in 0..<words where p.loadUnaligned(fromByteOffset: k * 8, as: UInt64.self) != 0 { return false }
            for k in (words * 8)..<length where raw[k] != 0 { return false }
            return true
        }
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        b.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    private static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        b.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }

    private static func errnoString() -> String { String(cString: strerror(errno)) }
}
