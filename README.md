# Proxmacs

A Proxmox-flavoured menubar VM manager for Apple Silicon Macs, built on [Tart](https://github.com/openai/tart).

- **Bridged networking**: VMs get their own LAN IP. Tart's official build is signed with Apple's
  `com.apple.vm.networking` entitlement, so it can use Virtualization.framework's native bridge.
- **Cloud images**: Debian 13 arm64 genericcloud, downloaded and converted from qcow2 to raw natively (no qemu-img).
  Provisioned with cloud-init: your `~/.ssh/*.pub` keys, an optional console password, and tart-guest-agent.
- **Backups**: instant APFS clones. When the guest agent is reachable, the root filesystem is frozen during the clone.
  Daily schedule and retention can be set per VM.
- **VMs outlive the app**: each VM runs as `tart run` under its own LaunchAgent (`dev.proxmacs.vm.<name>`).
  Optionally, a VM starts on login.

## Requirements

```bash
brew trust openai/tools && brew install openai/tools/tart
```

Use the Homebrew build. A Tart built from source lacks the bridging entitlement.

## Build & run

```bash
./scripts/build-app.sh && open build/Proxmacs.app
swift test
```

## CLI

The same binary has a scriptable mode that shares code with the menubar:

```bash
P=build/Proxmacs.app/Contents/MacOS/Proxmacs
$P cli create web1 --bridged en10 --disk 20 --password secret
$P cli list
$P cli backup web1 && $P cli backups web1
$P cli stop web1 && $P cli restore web1 0 && $P cli start web1
```

## Layout

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Proxmacs/images/` | cached base images (`*.raw`) and the agent `.deb` |
| `~/Library/Application Support/Proxmacs/vms/<name>/` | `meta.json`, `seed.iso` (cloud-init), `run.log` |
| `~/Library/Application Support/Proxmacs/backups/<name>/<timestamp>/` | cloned `disk.img`, `nvram.bin`, `config.json` |
| `~/.tart/vms/<name>/` | Tart's VM (owned by Tart) |
| `~/Library/LaunchAgents/dev.proxmacs.vm.<name>.plist` | per-VM runner |

## Notes

- Only arm64 guests boot. amd64 cloud images are rejected.
- Bridge over wired Ethernet. Wi-Fi access points often drop frames from bridged MACs.
- Backups live on the same disk. Off-host copies (`tart push` to an OCI registry, or restic) are future work.
- Tart is licensed under FSL-1.1-ALv2: fine for personal and internal use.
