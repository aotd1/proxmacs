#!/bin/bash
# Removes Proxmacs and everything it created on this Mac. Shows the plan and asks before deleting.
#
#   scripts/uninstall.sh [--dry-run] [--yes] [--keep-vms] [--keep-backups] [--keep-app]
#
#   --dry-run       only show what would be removed
#   --yes           don't ask for confirmation
#   --keep-vms      keep the Tart VMs (only stop them and remove their launch agents)
#   --keep-backups  keep local backups (backups/ in the data directory)
#   --keep-app      keep Proxmacs.app installed (it is still quit; reset data only)
#
# Not touched: Tart itself (brew uninstall tart), Tart VMs not created by Proxmacs, and snapshots
# already pushed to SMB shares or Proxmox Backup Servers.
set -euo pipefail

DRY=0 YES=0 KEEP_VMS=0 KEEP_BACKUPS=0 KEEP_APP=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --keep-vms) KEEP_VMS=1 ;;
    --keep-backups) KEEP_BACKUPS=1 ;;
    --keep-app) KEEP_APP=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

BUNDLE_ID=dev.proxmacs.app
SUPPORT="${PROXMACS_SUPPORT_DIR:-$HOME/Library/Application Support/Proxmacs}"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
TART="$(command -v tart || true)"
for candidate in /opt/homebrew/bin/tart /usr/local/bin/tart; do
  [ -n "$TART" ] || { [ -x "$candidate" ] && TART="$candidate"; } || true
done

size() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
run() {
  if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi
}

# --- What exists ----------------------------------------------------------------------------

# VMs Proxmacs manages: metadata directories plus launch agents (either may be left over alone).
VMS=$(
  {
    for dir in "$SUPPORT"/vms/*/; do [ -f "$dir/meta.json" ] && basename "$dir"; done
    for plist in "$AGENTS"/dev.proxmacs.vm.*.plist; do
      [ -e "$plist" ] && { name="${plist##*/dev.proxmacs.vm.}"; echo "${name%.plist}"; }
    done
  } 2>/dev/null | grep -E '^[a-z0-9][a-z0-9-]*$' | sort -u || true
)
TART_VMS=""
if [ -n "$TART" ]; then
  TART_VMS=$("$TART" list --source local --format json 2>/dev/null | /usr/bin/python3 -c \
    'import json,sys; print("\n".join(vm["Name"] for vm in json.load(sys.stdin)))' 2>/dev/null || true)
fi
tart_has() { printf '%s\n' "$TART_VMS" | grep -qx "$1"; }
tart_dir() { echo "${TART_HOME:-$HOME/.tart}/vms/$1"; }

APPS=""
if [ "$KEEP_APP" = 0 ]; then
  APPS=$(
    {
      mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true
      for dir in /Applications "$HOME/Applications"; do [ -d "$dir/Proxmacs.app" ] && echo "$dir/Proxmacs.app"; done
    } | grep -E '\.app$' | sort -u || true
  )
fi

LEFTOVERS=()
for path in \
  "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
  "$HOME/Library/Caches/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
  "/tmp/proxmacs-$(id -u)"; do
  [ -e "$path" ] && LEFTOVERS+=("$path")
done
for path in "${TMPDIR:-/tmp}"/proxmacs-*; do
  [ -e "$path" ] && LEFTOVERS+=("$path")
done

# --- Plan -----------------------------------------------------------------------------------

echo "Proxmacs uninstall plan"
echo
if [ -n "$VMS" ]; then
  echo "VMs (stopped, launch agents removed):"
  while read -r vm; do
    if [ "$KEEP_VMS" = 1 ]; then note="kept in Tart"
    elif tart_has "$vm"; then note="DELETED from Tart ($(size "$(tart_dir "$vm")") on disk)"
    else note="not in Tart"; fi
    echo "  $vm — $note"
  done <<< "$VMS"
else
  echo "VMs: none"
fi
echo
if [ -d "$SUPPORT" ]; then
  echo "Data directory: $SUPPORT ($(size "$SUPPORT"))"
  if [ -d "$SUPPORT/backups" ]; then
    if [ "$KEEP_BACKUPS" = 1 ]; then echo "  backups/ kept ($(size "$SUPPORT/backups"))"
    else echo "  including local backups ($(size "$SUPPORT/backups"))"; fi
  fi
  echo "  (settings, offsite targets, secrets, web certificate, cloud-init seeds, logs, cached images)"
else
  echo "Data directory: none"
fi
if [ -n "$APPS" ]; then
  echo
  echo "App bundles:"
  while read -r app; do echo "  $app"; done <<< "$APPS"
fi
if [ "${#LEFTOVERS[@]}" -gt 0 ]; then
  echo
  echo "Other files:"
  printf '  %s\n' "${LEFTOVERS[@]}"
fi
echo
echo "Not touched: Tart itself, other Tart VMs, and snapshots on SMB shares / Proxmox Backup Servers."
echo

if [ -z "$VMS" ] && [ ! -d "$SUPPORT" ] && [ -z "$APPS" ] && [ "${#LEFTOVERS[@]}" -eq 0 ]; then
  echo "Nothing to remove."
  exit 0
fi
if [ "$DRY" = 1 ]; then
  echo "Dry run: these steps would run:"
elif [ "$YES" = 0 ]; then
  read -r -p "Type 'uninstall' to continue: " answer
  [ "$answer" = uninstall ] || { echo "Aborted."; exit 1; }
fi

# --- Remove ---------------------------------------------------------------------------------

# Quit even with --keep-app: a running app would recreate the data directory.
echo "Quitting Proxmacs…"
run osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
run pkill -f 'Proxmacs.app/Contents/MacOS/Proxmacs$' || true
run pkill -f 'Proxmacs cli serve' || true

while read -r vm; do
  [ -n "$vm" ] || continue
  echo "Removing VM ${vm}…"
  if [ -n "$TART" ] && tart_has "$vm"; then
    # Graceful guest shutdown first; unloading the agent then ends the runner.
    run "$TART" stop "$vm" --timeout 30 2>/dev/null || true
  fi
  run launchctl bootout "$DOMAIN/dev.proxmacs.vm.$vm" 2>/dev/null || true
  run rm -f "$AGENTS/dev.proxmacs.vm.$vm.plist"
  if [ "$KEEP_VMS" = 0 ] && [ -n "$TART" ] && tart_has "$vm"; then
    run "$TART" delete "$vm"
  fi
done <<< "$VMS"

if [ -d "$SUPPORT" ]; then
  echo "Removing data directory…"
  if [ "$KEEP_BACKUPS" = 1 ] && [ -d "$SUPPORT/backups" ]; then
    run find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} +
  else
    run rm -rf "$SUPPORT"
  fi
fi

if [ "$KEEP_APP" = 0 ]; then
  run defaults delete "$BUNDLE_ID" 2>/dev/null || true
  while read -r app; do
    [ -n "$app" ] || continue
    echo "Removing ${app}…"
    run rm -rf "$app"
  done <<< "$APPS"
fi

for path in ${LEFTOVERS[@]+"${LEFTOVERS[@]}"}; do
  run rm -rf "$path"
done

echo
if [ "$DRY" = 1 ]; then
  echo "Dry run complete; nothing was changed."
else
  echo "Proxmacs removed."
  [ -n "$TART" ] && echo "Tart is still installed: brew uninstall tart && brew untap openai/tools"
fi
