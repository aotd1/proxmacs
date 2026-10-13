import Foundation
import NetFS

struct SMBLocation: Hashable {
    var host: String
    var share: String
    var user: String?
    /// Path inside the share where the Proxmacs store lives.
    var subpath: String

    /// smb://[user@]host/share[/sub/path]
    init(parsing string: String) throws {
        guard let components = URLComponents(string: string), components.scheme?.lowercased() == "smb",
              let host = components.host, !host.isEmpty else {
            throw ProxmacsError("Invalid SMB URL \(string); expected smb://user@host/share[/path]")
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let share = parts.first else { throw ProxmacsError("SMB URL \(string) has no share name") }
        self.host = host
        self.share = share
        self.user = components.user?.removingPercentEncoding
        self.subpath = parts.dropFirst().joined(separator: "/")
    }

    var shareURL: URL {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.user = user
        components.path = "/\(share)"
        return components.url!
    }
}

/// Mounts SMB shares via NetFS (no UI), reusing an existing mount of the same share if present.
enum SMBMount {
    static func withMount<T>(_ location: SMBLocation, password: String?, _ body: (URL) async throws -> T) async throws -> T {
        if let existing = existingMount(location) {
            return try await body(existing)
        }
        let mountPoint = try await mount(location, password: password)
        defer { unmount(mountPoint.path, 0) }
        return try await body(mountPoint)
    }

    private static func existingMount(_ location: SMBLocation) -> URL? {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return nil }
        for i in 0..<Int(count) {
            var entry = mounts[i]
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard type == "smbfs" else { continue }
            // f_mntfromname looks like //user@host/share or //;DOMAIN;user@host/share
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            var rest = from.hasPrefix("//") ? String(from.dropFirst(2)) : from
            if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            let hostShare = rest.split(separator: "/", maxSplits: 1)
            guard hostShare.count == 2,
                  hostShare[0].lowercased() == location.host.lowercased(),
                  hostShare[1].removingPercentEncoding?.lowercased() == location.share.lowercased() else { continue }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return URL(fileURLWithPath: on, isDirectory: true)
        }
        return nil
    }

    private static func mount(_ location: SMBLocation, password: String?) async throws -> URL {
        let url = location.shareURL
        let user = location.user
        return try await Task.detached {
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            let mountOptions = NSMutableDictionary()
            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                url as CFURL, nil,
                user as CFString?, password as CFString?,
                openOptions, mountOptions, &mountpoints
            )
            guard status == 0, let paths = mountpoints?.takeRetainedValue() as? [String], let path = paths.first else {
                throw ProxmacsError("Mounting \(url.absoluteString) failed (\(status): \(String(cString: strerror(status))))")
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }.value
    }
}
