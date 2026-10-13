import CShims
import Foundation
import libzstd

enum DataBlobError: LocalizedError {
    case tooShort
    case unknownMagic
    case encrypted
    case crcMismatch
    case zstd(String)

    var errorDescription: String? {
        switch self {
        case .tooShort: "data blob too short"
        case .unknownMagic: "unknown data blob magic"
        case .encrypted: "encrypted data blobs are not supported"
        case .crcMismatch: "data blob CRC mismatch"
        case .zstd(let message): "zstd: \(message)"
        }
    }
}

/// Proxmox Backup Server "Data Blob" encoding: 8-byte magic, CRC32 (LE) of the payload, payload
/// (raw or zstd). Used for PBS chunks/blobs and, for uniformity, by the SMB chunk store.
enum DataBlob {
    static let uncompressedMagic: [UInt8] = [66, 171, 56, 7, 190, 131, 112, 161]
    static let compressedMagic: [UInt8] = [49, 185, 88, 66, 111, 182, 163, 127]
    static let encryptedMagic: [UInt8] = [123, 103, 133, 190, 34, 45, 76, 240]
    static let encryptedCompressedMagic: [UInt8] = [230, 89, 27, 191, 11, 191, 216, 11]
    static let headerSize = 12
    static let maxSize = 16 * 1024 * 1024

    static func encode(_ data: Data, compress: Bool = true) -> Data {
        var payload = data
        var magic = uncompressedMagic
        if compress, !data.isEmpty {
            let bound = ZSTD_compressBound(data.count)
            var compressed = Data(count: bound)
            let written = compressed.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    ZSTD_compress(dst.baseAddress, bound, src.baseAddress, data.count, 1)
                }
            }
            // Like PBS: only keep the compressed form if it is actually smaller.
            if ZSTD_isError(written) == 0, written < data.count {
                payload = compressed.prefix(written)
                magic = compressedMagic
            }
        }
        var out = Data(capacity: headerSize + payload.count)
        out.append(contentsOf: magic)
        var crc = crc32(payload).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func decode(_ blob: Data) throws -> Data {
        guard blob.count >= headerSize else { throw DataBlobError.tooShort }
        let magic = [UInt8](blob.prefix(8))
        let payload = blob.dropFirst(headerSize)
        let storedCRC = blob.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }

        switch magic {
        case uncompressedMagic, compressedMagic:
            guard crc32(payload) == storedCRC else { throw DataBlobError.crcMismatch }
        case encryptedMagic, encryptedCompressedMagic:
            throw DataBlobError.encrypted
        default:
            throw DataBlobError.unknownMagic
        }
        return magic == compressedMagic ? try zstdDecompress(Data(payload)) : Data(payload)
    }

    static func crc32(_ data: some DataProtocol) -> UInt32 {
        let bytes = Data(data)
        return bytes.withUnsafeBytes { raw in
            UInt32(CShims.crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
    }

    private static func zstdDecompress(_ data: Data) throws -> Data {
        let stream = ZSTD_createDStream()
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)

        var output = Data()
        let chunk = ZSTD_DStreamOutSize()
        var buffer = [UInt8](repeating: 0, count: chunk)
        try data.withUnsafeBytes { src in
            var input = ZSTD_inBuffer(src: src.baseAddress, size: data.count, pos: 0)
            while true {
                let produced: Int = try buffer.withUnsafeMutableBytes { dst in
                    var out = ZSTD_outBuffer(dst: dst.baseAddress, size: chunk, pos: 0)
                    let ret = ZSTD_decompressStream(stream, &out, &input)
                    if ZSTD_isError(ret) != 0 { throw DataBlobError.zstd(String(cString: ZSTD_getErrorName(ret))) }
                    return out.pos
                }
                output.append(contentsOf: buffer[0..<produced])
                if output.count > maxSize { throw DataBlobError.zstd("decompressed data exceeds 16 MiB") }
                if input.pos >= input.size && produced < chunk { break }
            }
        }
        return output
    }
}
