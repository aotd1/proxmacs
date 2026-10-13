# Proxmacs

A Proxmox-flavoured menubar VM manager for Apple Silicon Macs, built on [Tart](https://github.com/openai/tart).

- **Bridged networking**: VMs get their own LAN IP. Tart's official build is signed with Apple's
  `com.apple.vm.networking` entitlement, so it can use Virtualization.framework's native bridge.
- **Cloud images**: Debian 13 arm64 genericcloud, downloaded and converted from qcow2 to raw natively (no qemu-img).
  Provisioned with cloud-init: user (default `debian`, passwordless sudo), SSH keys (default: your `~/.ssh/*.pub`),
  an optional console password (stored only as a SHA-512 crypt hash), DHCP or a static IPv4, and tart-guest-agent.
- **Editing VMs**: CPUs, memory, disk (grow only; the root filesystem grows on next boot) and network while stopped.
  Cloud-init settings (user, password, SSH keys, IP) can be changed any time: the seed is rebuilt with a new
  instance-id and cloud-init re-applies them on the next start. `authorized_keys` ends up exactly as configured, and
  SSH host keys are kept.
- **Backups**: instant APFS clones. When the guest agent is reachable, the root filesystem is frozen during the clone.
  Daily schedule and retention can be set per VM.
- **Offsite backups** push local backups as deduplicated, incremental 4 MiB chunks (only changed chunks travel):
  - **SMB share**: a PBS-like chunk store (`proxmacs-store/`) on any SMB share, mounted on demand via NetFS.
  - **Proxmox Backup Server**: a native Swift client for the PBS backup/reader protocols (HTTP/2 upgrade,
    `disk.img.fidx` + blobs, zstd), authenticated with an API token and certificate fingerprint pinning.
  - Pull a remote snapshot back into local backups. If the VM no longer exists, pulling recreates it.
- **Web UI**, Proxmox-style, at `https://<mac>:8006` (React + TypeScript, in `web/`): password login, VM list,
  actions and editing, host memory usage (Activity Monitor's breakdown, pressure, swap, memory assigned to running
  VMs, live chart), task log, backups/offsite management, and a browser serial console (xterm.js over WebSocket).
  The menubar shows a memory gauge too.
- **VMs outlive the app**: each VM runs under its own LaunchAgent (`dev.proxmacs.vm.<name>`) as
  `Proxmacs cli run-vm <name>`, which supervises `tart run` and owns the serial console
  (socket `/tmp/proxmacs-<uid>/<name>.sock`, scrollback in `vms/<name>/console.log`).
  Optionally, a VM starts on login.

## Requirements

```bash
brew trust openai/tools && brew install openai/tools/tart
```

Use the Homebrew build. A Tart built from source lacks the bridging entitlement.

## Build & run

```bash
./scripts/build-app.sh && open build/Proxmacs.app     # needs Node.js for the web UI
swift test
```

Web UI development: `npm --prefix web run build` produces `web/dist`, which a debug build serves directly. For hot
reload, run `npm --prefix web run dev` (Vite on :5173) next to a running Proxmacs. It proxies `/api` to
`PROXMACS_URL` (default `https://127.0.0.1:8006`).

## CLI

The same binary has a scriptable mode that shares code with the menubar:

```bash
P=build/Proxmacs.app/Contents/MacOS/Proxmacs
$P cli create web1 --bridged en10 --disk 20 --password secret
$P cli create db1 --nat --user admin --ssh-keys ~/.ssh/id_ed25519.pub --ip 192.168.64.50/24 --gateway 192.168.64.1
$P cli edit web1 --cpus 4 --memory 8192 --disk 40      # VM stopped
$P cli edit web1 --password --dhcp                     # prompts; applied on next start
$P cli list
$P cli backup web1 && $P cli backups web1
$P cli stop web1 && $P cli restore web1 0 && $P cli start web1
```

### Offsite

```bash
$P cli target-add smb nas smb://backup@nas.local/vmbackups/proxmacs --keep 14   # prompts for the password
$P cli target-add pbs pbs1 --host pbs.lan --datastore store1 --auth-id 'proxmacs@pbs!mac' \
      --fingerprint 'aa:bb:…' --keep 14                                           # prompts for the token secret
$P cli target-test pbs1
$P cli push web1 pbs1            # newest local backup → PBS
$P cli remote pbs1 web1          # list snapshots
$P cli pull pbs1 web1            # newest snapshot → local backups (recreates web1 if it's gone)
```

The PBS token needs `DatastoreBackup` on the datastore, or the namespace if you use one. Pruning remote
snapshots also needs `Datastore.Prune`; without it, pushes still succeed and the task notes that pruning failed.

### Web UI

```bash
$P cli web-passwd                # or Proxmacs menu → Web UI → Set Password…
$P cli serve                     # headless, without the menubar
```

Settings live in `web.json` (`enabled`, `port` 8006, `bind` 0.0.0.0, `tls` true). The self-signed certificate's
SHA-256 fingerprint is printed by `serve`, so you can check it against the browser warning.

## Layout

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Proxmacs/images/` | cached base images (`*.raw`) and the agent `.deb` |
| `~/Library/Application Support/Proxmacs/vms/<name>/` | `meta.json` (incl. cloud-init settings), `seed.iso` (cloud-init), `run.log`, `console.log` |
| `~/Library/Application Support/Proxmacs/backups/<name>/<timestamp>/` | cloned `disk.img`, `nvram.bin`, `config.json` |
| `~/Library/Application Support/Proxmacs/offsite.json` | offsite targets |
| `~/Library/Application Support/Proxmacs/secrets.json` | SMB passwords, PBS token secrets, web password hash (mode 0600) |
| `~/Library/Application Support/Proxmacs/web.json` | web UI settings |
| `~/Library/Application Support/Proxmacs/web/` | self-signed `cert.pem` / `key.pem` |
| `~/.tart/vms/<name>/` | Tart's VM (owned by Tart) |
| `~/Library/LaunchAgents/dev.proxmacs.vm.<name>.plist` | per-VM runner |

## Uninstall

```bash
./scripts/uninstall.sh --dry-run     # show what would be removed
./scripts/uninstall.sh               # asks you to type 'uninstall'
```

The script quits the app and stops every Proxmacs VM. It then removes:

- their launch agents
- their Tart VMs
- the data directory: settings, secrets, certificate, seeds, logs, cached images and local backups
- the app bundle(s), preferences, caches and the console sockets

Options: `--keep-vms`, `--keep-backups`, `--keep-app`, `--yes`. Tart itself, Tart VMs that Proxmacs didn't create,
and snapshots already pushed to SMB or PBS are left alone.

## Notes

- Only arm64 guests boot. amd64 cloud images are rejected.
- Changing the cloud-init user adds a new account; the old one is kept. VMs created before cloud-init settings were
  stored show the password as "unchanged since creation" and leave it alone until you set or remove one.
- Bridge over wired Ethernet. Wi-Fi access points often drop frames from bridged MACs.
- Local backups live on the same disk; push them offsite (SMB/PBS) for real protection.
- Secrets are kept in an owner-only file rather than the Keychain: the login Keychain prompts after every rebuild
  of an ad-hoc-signed binary.
- Tart is licensed under FSL-1.1-ALv2: fine for personal and internal use.
