import Foundation

/// Read Tart's cross-user process lock without acquiring it or relying on launchd's wrapper PID.
enum VMProcess {
    static func lockPID(_ name: String) -> pid_t? {
        guard name.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else { return nil }
        let fd = open(Paths.tartVMDir(name).appending(path: "config.json").path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_RDLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return nil }
        return lock.l_type == Int16(F_UNLCK) ? 0 : lock.l_pid
    }
}
