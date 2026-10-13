#!/bin/bash
# Builds build/Proxmacs.app. IDENTITY=<codesign identity> overrides ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

# Web UI (React): needs Node.js.
npm --prefix web ci --no-audit --no-fund
npm --prefix web run build

swift build -c release --product Proxmacs
BIN="$(swift build -c release --show-bin-path)/Proxmacs"

APP=build/Proxmacs.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Proxmacs"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R web/dist "$APP/Contents/Resources/WebAssets"

codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
