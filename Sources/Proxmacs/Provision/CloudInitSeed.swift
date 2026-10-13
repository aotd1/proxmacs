import Foundation

/// Builds a cloud-init NoCloud seed ISO (volume label `cidata`) for a VM.
/// The tart-guest-agent .deb is baked into the ISO so first boot needs no internet to install it.
///
/// Every build gets a fresh instance-id, so editing a VM's settings and rebuilding the seed makes
/// cloud-init treat the next boot as a new instance and apply user, keys, password and network again.
enum CloudInitSeed {
    /// The host user's OpenSSH public keys (~/.ssh/*.pub). Files in other formats (e.g. RFC 4716
    /// "---- BEGIN SSH2 PUBLIC KEY ----") and DSA keys, which modern OpenSSH rejects, are skipped.
    static func sshPublicKeys() -> [String] {
        let sshDir = Paths.home.appending(path: ".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sshDir.path)) ?? []
        return files.filter { $0.hasSuffix(".pub") }.sorted().flatMap { file -> [String] in
            guard let text = try? String(contentsOf: sshDir.appending(path: file), encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter(CloudInitConfig.isValidKey)
        }
    }

    static func userData(hostname: String, config: CloudInitConfig) -> String {
        var lines = [
            "#cloud-config",
            "hostname: \(q(hostname))",
            "manage_etc_hosts: true",
            "ssh_pwauth: false",
            // Re-provisioning (new instance-id) must not replace the guest's SSH host keys.
            "ssh_deletekeys: false",
            "users:",
            "  - name: \(q(config.user))",
            "    groups: [adm, sudo]",
            "    sudo: \(q("ALL=(ALL) NOPASSWD:ALL"))",
            "    shell: /bin/bash",
            // Password state is handled by proxmacs-provision below; cloud-init must not lock it.
            "    lock_passwd: false",
        ]
        if !config.sshKeys.isEmpty {
            lines.append("    ssh_authorized_keys:")
            lines += config.sshKeys.map { "      - \(q($0))" }
        }
        lines += [
            "write_files:",
            // The packaged unit runs as User=admin (a macOS-guest convention); Debian has no such user,
            // and fsfreeze for backups needs root anyway.
            "  - path: /etc/systemd/system/tart-guest-agent.service.d/proxmacs.conf",
            "    content: |",
            "      [Service]",
            "      User=root",
            "  - path: /etc/proxmacs/authorized_keys",
            "    permissions: '0644'",
            "    content: \(q(config.sshKeys.map { $0 + "\n" }.joined()))",
            "  - path: /usr/local/sbin/proxmacs-provision",
            "    permissions: '0700'",
            "    content: |",
        ]
        lines += provisionScript(config).split(separator: "\n", omittingEmptySubsequences: false).map { "      \($0)" }
        lines += [
            "runcmd:",
            "  - [/usr/local/sbin/proxmacs-provision]",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs once per instance (i.e. after every seed rebuild): installs the guest agent and makes the
    /// user's authorized_keys and password exactly what Proxmacs has configured.
    static func provisionScript(_ config: CloudInitConfig) -> String {
        // Values are validated (user name, $6$ hash alphabet), so single-quoting is safe.
        var script = """
        #!/bin/sh
        set -u
        user='\(config.user)'
        dev=$(blkid -t LABEL=cidata -o device | head -n1)
        [ -n "$dev" ] || dev=$(blkid -t LABEL=CIDATA -o device | head -n1)
        mkdir -p /mnt/cidata
        if mount -o ro "$dev" /mnt/cidata; then
          dpkg -i /mnt/cidata/tart-guest-agent.deb
          umount /mnt/cidata
        fi
        systemctl daemon-reload
        systemctl enable tart-guest-agent
        systemctl restart tart-guest-agent
        home=$(getent passwd "$user" | cut -d: -f6)
        if [ -n "$home" ]; then
          group=$(id -g "$user")
          install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
          install -m 600 -o "$user" -g "$group" /etc/proxmacs/authorized_keys "$home/.ssh/authorized_keys"
        fi

        """
        if config.managePassword {
            if let hash = config.passwordHash {
                script += "usermod -p '\(hash)' \"$user\"\n"
            } else {
                script += "passwd -l \"$user\"\n"
            }
        }
        return script
    }

    static func networkConfig(_ network: GuestNetwork) -> String {
        // DHCP with the MAC as client identifier: systemd-networkd defaults to a DUID, which macOS's
        // bootpd records instead of the MAC, so `tart ip --resolver dhcp` could never find the lease.
        var lines = [
            "version: 2",
            "ethernets:",
            "  primary:",
            "    match:",
            "      name: \"en*\"",
        ]
        if network.dhcp {
            lines += ["    dhcp4: true", "    dhcp-identifier: mac"]
        } else {
            lines += ["    dhcp4: false", "    addresses: [\(q(network.address ?? ""))]"]
            if let gateway = network.gateway, !gateway.isEmpty {
                lines += ["    routes:", "      - to: 0.0.0.0/0", "        via: \(q(gateway))"]
            }
            if !network.dns.isEmpty {
                lines += ["    nameservers:", "      addresses: [\(network.dns.map(q).joined(separator: ", "))]"]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func build(name: String, config: CloudInitConfig, agentDeb: URL) async throws {
        try config.validate()
        let stage = FileManager.default.temporaryDirectory.appending(path: "proxmacs-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let metaData = "instance-id: \(UUID().uuidString.lowercased())\nlocal-hostname: \(name)\n"
        try metaData.write(to: stage.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try userData(hostname: name, config: config).write(to: stage.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try networkConfig(config.network).write(to: stage.appending(path: "network-config"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: agentDeb, to: stage.appending(path: "tart-guest-agent.deb"))

        // Build next to the old seed and swap, so a failed build leaves the VM bootable.
        let iso = Paths.seedISO(name)
        try FileManager.default.createDirectory(at: iso.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = iso.deletingLastPathComponent().appending(path: "seed-new.iso")
        try? FileManager.default.removeItem(at: fresh)
        try await Shell.check("/usr/bin/hdiutil", [
            "makehybrid", "-quiet", "-o", fresh.path, stage.path,
            "-iso", "-joliet", "-default-volume-name", "cidata",
        ])
        if FileManager.default.fileExists(atPath: iso.path) {
            _ = try FileManager.default.replaceItemAt(iso, withItemAt: fresh)
        } else {
            try FileManager.default.moveItem(at: fresh, to: iso)
        }
        // The seed holds the password hash.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: iso.path)
    }

    /// YAML-safe scalar: a JSON string literal is valid YAML.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    private static func q(_ s: String) -> String {
        let data = (try? encoder.encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
