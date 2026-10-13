import Foundation

/// Builds a cloud-init NoCloud seed ISO (volume label `cidata`) for a VM.
/// The tart-guest-agent .deb is baked into the ISO so first boot needs no internet to install it.
enum CloudInitSeed {
    static func sshPublicKeys() -> [String] {
        let sshDir = Paths.home.appending(path: ".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sshDir.path)) ?? []
        return files.filter { $0.hasSuffix(".pub") }.sorted().compactMap { file in
            guard let key = try? String(contentsOf: sshDir.appending(path: file), encoding: .utf8) else { return nil }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            // Modern OpenSSH rejects DSA keys; skip them.
            return trimmed.isEmpty || trimmed.hasPrefix("ssh-dss") ? nil : trimmed
        }
    }

    static func userData(hostname: String, password: String?, sshKeys: [String]) -> String {
        var lines = [
            "#cloud-config",
            "hostname: \(q(hostname))",
            "manage_etc_hosts: true",
            "ssh_pwauth: false",
            "ssh_authorized_keys:",
        ]
        lines += sshKeys.map { "  - \(q($0))" }
        if let password, !password.isEmpty {
            lines += [
                "chpasswd:",
                "  expire: false",
                "  users:",
                "    - {name: debian, password: \(q(password)), type: text}",
            ]
        }
        lines += [
            "write_files:",
            // The packaged unit runs as User=admin (a macOS-guest convention); Debian has no such user,
            // and fsfreeze for backups needs root anyway.
            "  - path: /etc/systemd/system/tart-guest-agent.service.d/proxmacs.conf",
            "    content: |",
            "      [Service]",
            "      User=root",
            "  - path: /usr/local/sbin/proxmacs-firstboot",
            "    permissions: '0755'",
            "    content: |",
            "      #!/bin/sh",
            "      set -u",
            "      dev=$(blkid -t LABEL=cidata -o device | head -n1)",
            "      [ -n \"$dev\" ] || dev=$(blkid -t LABEL=CIDATA -o device | head -n1)",
            "      mkdir -p /mnt/cidata",
            "      if mount -o ro \"$dev\" /mnt/cidata; then",
            "        dpkg -i /mnt/cidata/tart-guest-agent.deb",
            "        umount /mnt/cidata",
            "      fi",
            "      systemctl daemon-reload",
            "      systemctl enable tart-guest-agent",
            "      systemctl restart tart-guest-agent",
            "runcmd:",
            "  - [/usr/local/sbin/proxmacs-firstboot]",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// DHCP with the MAC as client identifier: systemd-networkd defaults to a DUID, which macOS's
    /// bootpd records instead of the MAC, so `tart ip --resolver dhcp` could never find the lease.
    static let networkConfig = """
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        dhcp4: true
        dhcp-identifier: mac

    """

    static func build(name: String, password: String?, agentDeb: URL) async throws {
        let stage = FileManager.default.temporaryDirectory.appending(path: "proxmacs-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let metaData = "instance-id: \(UUID().uuidString.lowercased())\nlocal-hostname: \(name)\n"
        try metaData.write(to: stage.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try userData(hostname: name, password: password, sshKeys: sshPublicKeys())
            .write(to: stage.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try networkConfig.write(to: stage.appending(path: "network-config"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: agentDeb, to: stage.appending(path: "tart-guest-agent.deb"))

        let iso = Paths.seedISO(name)
        try FileManager.default.createDirectory(at: iso.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: iso)
        try await Shell.check("/usr/bin/hdiutil", [
            "makehybrid", "-quiet", "-o", iso.path, stage.path,
            "-iso", "-joliet", "-default-volume-name", "cidata",
        ])
    }

    /// YAML-safe scalar: a JSON string literal is valid YAML.
    private static func q(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
