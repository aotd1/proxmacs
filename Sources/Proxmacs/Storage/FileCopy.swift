import Foundation

/// Copies VM files between volumes. Within a volume files are APFS clones (instant); across
/// volumes only the data regions are copied, so sparse disk images stay sparse, and the copy is
/// flushed to the drive before returning (callers may delete the source afterwards).
enum FileCopy {
    /// Called with the number of bytes (of logical file size) handled since the last call.
    typealias Progress = (Int64) -> Void

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func device(_ url: URL) -> dev_t? {
            var existing = url
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
            var st = stat()
            return stat(existing.path, &st) == 0 ? st.st_dev : nil
        }
        guard let da = device(a), let db = device(b) else { return false }
        return da == db
    }

    /// Logical size of a file or directory tree (what progress is measured against).
    static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return fileSize(url) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            if let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Space a file or tree actually occupies (sparse regions excluded).
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            if let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Copies one regular file; `destination` must not exist.
    static func copy(_ source: URL, to destination: URL, progress: Progress? = nil) throws {
        if clonefile(source.path, destination.path, 0) == 0 {
            progress?(fileSize(source))
            return
        }
        guard errno == EXDEV || errno == ENOTSUP else { throw posixError(errno, source) }
        try sparseCopy(source, to: destination, progress: progress)
    }

    /// Copies a directory tree (regular files, directories and symlinks); `destination` must not exist.
    static func copyTree(_ source: URL, to destination: URL, progress: Progress? = nil) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw posixError(ENOENT, source) }
        guard isDirectory.boolValue else { return try copy(source, to: destination, progress: progress) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            let from = source.appending(path: name), to = destination.appending(path: name)
            let values = try from.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                try FileManager.default.createSymbolicLink(atPath: to.path, withDestinationPath: FileManager.default.destinationOfSymbolicLink(atPath: from.path))
            } else if values.isDirectory == true {
                try copyTree(from, to: to, progress: progress)
            } else if values.isRegularFile == true {
                try copy(from, to: to, progress: progress)
            }
            // Sockets, FIFOs (e.g. a stale console socket) are skipped.
        }
    }

    /// Moves a file or tree: a rename within a volume, otherwise copy, then delete the source.
    static func move(_ source: URL, to destination: URL, progress: Progress? = nil) throws {
        if rename(source.path, destination.path) == 0 {
            progress?(size(of: destination))
            return
        }
        guard errno == EXDEV else { throw posixError(errno, source) }
        do {
            try copyTree(source, to: destination, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try FileManager.default.removeItem(at: source)
    }

    /// Exposed for tests; use `copy`.
    static func sparseCopy(_ source: URL, to destination: URL, progress: Progress?) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw posixError(errno, source) }
        defer { close(input) }
        var st = stat()
        guard fstat(input, &st) == 0 else { throw posixError(errno, source) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0o777)
        guard output >= 0 else { throw posixError(errno, destination) }
        var completed = false
        defer {
            close(output)
            if !completed { unlink(destination.path) }
        }

        let size = st.st_size
        guard ftruncate(output, size) == 0 else { throw posixError(errno, destination) }
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }

        var offset: off_t = 0
        var reported: off_t = 0
        func report(_ position: off_t) {
            if position > reported { progress?(Int64(position - reported)); reported = position }
        }
        while offset < size {
            // Skip holes; if the filesystem can't tell, treat everything as data.
            var dataStart = lseek(input, offset, SEEK_DATA)
            if dataStart < 0 {
                if errno == ENXIO { break }  // only a hole remains
                dataStart = offset
            }
            var dataEnd = lseek(input, dataStart, SEEK_HOLE)
            if dataEnd < 0 || dataEnd > size { dataEnd = size }
            var position = dataStart
            while position < dataEnd {
                let wanted = Int(min(off_t(chunk), dataEnd - position))
                let n = pread(input, buffer, wanted, position)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw posixError(n == 0 ? EIO : errno, source) }
                // Zero blocks inside data regions stay holes too (freshly converted images have many).
                if !isZero(buffer, n) {
                    var written = 0
                    while written < n {
                        let w = pwrite(output, buffer + written, n - written, position + off_t(written))
                        if w < 0 && errno == EINTR { continue }
                        guard w > 0 else { throw posixError(errno, destination) }
                        written += w
                    }
                }
                position += off_t(n)
                report(position)
            }
            offset = dataEnd
        }
        report(size)
        // External drives can be unplugged: make sure the copy is on the medium before the source goes.
        guard fcntl(output, F_FULLFSYNC) == 0 || fsync(output) == 0 else { throw posixError(errno, destination) }
        completed = true
    }

    private static func isZero(_ buffer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        for i in stride(from: 0, to: count / 8 * 8, by: 8) where buffer.load(fromByteOffset: i, as: UInt64.self) != 0 { return false }
        for i in (count / 8 * 8)..<count where buffer.load(fromByteOffset: i, as: UInt8.self) != 0 { return false }
        return true
    }

    private static func posixError(_ code: Int32, _ url: URL) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path,
                                                                     NSLocalizedDescriptionKey: "\(url.path): \(String(cString: strerror(code)))"])
    }
}
