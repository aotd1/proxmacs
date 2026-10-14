import Foundation

/// Builds a cloud-init NoCloud seed ISO (volume label `cidata`) for a VM.
/// The tart-guest-agent packages (.deb and .rpm) are baked into the ISO so first boot needs no internet
/// to install the agent.
///
/// Every build gets a fresh instance-id, so editing a VM's settings and rebuilding the seed makes
/// cloud-init treat the next boot as a new instance and apply user, keys, password and network again.
enum CloudInitSeed {
    /// Bumped when seeds gain something older seeds lack (2: the shared-folder mount unit).
    static let version = 2
    static func versionFile(_ vm: String) -> URL { Paths.vmDir(vm).appending(path: "seed-version") }

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

    /// Where the provisioning script records the instance-id it finished (see `ProvisionState`).
    static let provisionedMarker = "/var/lib/proxmacs/provisioned"

    /// `newIdentity`: a clone's first boot, which must not keep its source's SSH host keys and machine-id.
    /// `instance`: the seed's instance-id, recorded in the guest once provisioning finishes.
    static func userData(hostname: String, config: CloudInitConfig, newIdentity: Bool = false, instance: String? = nil) -> String {
        var lines = [
            "#cloud-config",
            "hostname: \(q(hostname))",
            "manage_etc_hosts: true",
            "ssh_pwauth: false",
            // Re-provisioning (new instance-id) must not replace the guest's SSH host keys; clones get new ones.
            "ssh_deletekeys: \(newIdentity)",
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
            // Shared folders (tart run --dir) all use Tart's default tag: one virtiofs, a directory per share.
            "  - path: /etc/systemd/system/proxmacs-shares.service",
            "    content: |",
            "      [Unit]",
            "      Description=Mount Proxmacs shared folders at /mnt/shared",
            "      After=local-fs.target",
            "      [Service]",
            "      Type=oneshot",
            "      RemainAfterExit=yes",
            "      ExecStartPre=-/sbin/modprobe virtiofs",
            "      ExecStart=/bin/sh -c 'grep -qsx com.apple.virtio-fs.automount /sys/fs/virtiofs/*/tag || exit 0; mkdir -p /mnt/shared; mountpoint -q /mnt/shared || mount -t virtiofs com.apple.virtio-fs.automount /mnt/shared'",
            "      [Install]",
            "      WantedBy=multi-user.target",
            "  - path: /etc/proxmacs/authorized_keys",
            "    permissions: '0644'",
            "    content: \(q(config.sshKeys.map { $0 + "\n" }.joined()))",
            "  - path: /usr/local/sbin/proxmacs-provision",
            "    permissions: '0700'",
            "    content: |",
        ]
        lines += provisionScript(config, newIdentity: newIdentity, instance: instance).split(separator: "\n", omittingEmptySubsequences: false).map { "      \($0)" }
        lines += [
            "runcmd:",
            "  - [/usr/local/sbin/proxmacs-provision]",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Runs once per instance (i.e. after every seed rebuild): installs the guest agent and makes the
    /// user's authorized_keys and password exactly what Proxmacs has configured.
    static func provisionScript(_ config: CloudInitConfig, newIdentity: Bool = false, instance: String? = nil) -> String {
        // Values are validated (user name, $6$ hash alphabet), so single-quoting is safe.
        var script = """
        #!/bin/sh
        set -u
        user='\(config.user)'
        dev=$(blkid -t LABEL=cidata -o device | head -n1)
        [ -n "$dev" ] || dev=$(blkid -t LABEL=CIDATA -o device | head -n1)
        mkdir -p /mnt/cidata
        if mount -o ro "$dev" /mnt/cidata; then
          if command -v dpkg >/dev/null; then
            dpkg -i /mnt/cidata/tart-guest-agent.deb
          elif command -v rpm >/dev/null; then
            rpm -U --replacepkgs /mnt/cidata/tart-guest-agent.rpm
          fi
          umount /mnt/cidata
        fi
        systemctl daemon-reload
        systemctl enable tart-guest-agent
        systemctl restart tart-guest-agent
        systemctl enable --now proxmacs-shares.service
        # A first boot cut short can leave empty host key files; cloud-init keeps existing keys, and sshd
        # won't start with them.
        regen=
        for key in /etc/ssh/ssh_host_*_key; do
          [ -e "$key" ] || continue
          if ! { [ -s "$key" ] && [ -s "$key.pub" ] && ssh-keygen -l -f "$key.pub" >/dev/null 2>&1; }; then
            rm -f "$key" "$key.pub"
            regen=1
          fi
        done
        if [ -n "$regen" ]; then
          ssh-keygen -A
          systemctl reset-failed ssh sshd 2>/dev/null
          systemctl restart ssh 2>/dev/null || systemctl restart sshd
        fi
        home=$(getent passwd "$user" | cut -d: -f6)
        if [ -n "$home" ]; then
          group=$(id -g "$user")
          install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
          install -m 600 -o "$user" -g "$group" /etc/proxmacs/authorized_keys "$home/.ssh/authorized_keys"
        fi

        """
        if newIdentity {
            script += """
            rm -f /etc/machine-id
            systemd-machine-id-setup
            if [ -e /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
              ln -sf /etc/machine-id /var/lib/dbus/machine-id
            fi

            """
        }
        if config.managePassword {
            if let hash = config.passwordHash {
                script += "usermod -p '\(hash)' \"$user\"\n"
            } else {
                script += "passwd -l \"$user\"\n"
            }
        }
        if let instance {
            // Last, so the host only sees it once everything above has run.
            script += "mkdir -p \(URL(fileURLWithPath: provisionedMarker).deletingLastPathComponent().path)\n"
            script += "echo '\(instance)' > \(provisionedMarker)\n"
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

    static func build(name: String, config: CloudInitConfig, agentPackages: [URL], newIdentity: Bool = false) async throws {
        try config.validate()
        let stage = FileManager.default.temporaryDirectory.appending(path: "proxmacs-seed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let instance = UUID().uuidString.lowercased()
        let metaData = "instance-id: \(instance)\nlocal-hostname: \(name)\n"
        try metaData.write(to: stage.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try userData(hostname: name, config: config, newIdentity: newIdentity, instance: instance).write(to: stage.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try networkConfig(config.network).write(to: stage.appending(path: "network-config"), atomically: true, encoding: .utf8)
        for package in agentPackages {
            try FileManager.default.copyItem(at: package, to: stage.appending(path: "tart-guest-agent.\(package.pathExtension)"))
        }

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
        try? Data(String(version).utf8).write(to: versionFile(name))
        ProvisionState(instance: instance).save(name)
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

/// Whether the guest finished provisioning from the current seed. cloud-init marks each per-instance
/// module done as it starts it, so a first boot cut short (the VM stopped early) never gets the guest
/// agent, users or keys. VMRunner then rebuilds the seed with a new instance-id, which makes cloud-init
/// start over. Seeds built before this existed have no state and are left alone.
struct ProvisionState: Codable, Equatable {
    var instance: String
    /// A boot from this seed has started.
    var booted = false
    /// The guest reported (through the agent) that provisioning ran to the end.
    var done = false
    /// Rebuilds because provisioning didn't finish; capped so a guest that can never report back
    /// (e.g. no agent for its distribution) isn't re-provisioned on every boot.
    var retries = 0

    static let maxRetries = 2

    var needsRetry: Bool { booted && !done && retries < Self.maxRetries }

    static func file(_ vm: String) -> URL { Paths.vmDir(vm).appending(path: "provision.json") }

    static func load(_ vm: String) -> ProvisionState? {
        guard let data = try? Data(contentsOf: file(vm)) else { return nil }
        return try? JSONDecoder().decode(ProvisionState.self, from: data)
    }

    func save(_ vm: String) {
        try? JSONEncoder().encode(self).write(to: Self.file(vm), options: .atomic)
    }
}
