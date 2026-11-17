#!/bin/zsh
# Regenerates Resources/AppIcon.icns, docs/icon.png and docs/favicon.png from tools/make_icon.m.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
mkdir -p "$WORK/AppIcon.iconset" Resources
clang -fobjc-arc -framework Cocoa tools/make_icon.m -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/AppIcon.iconset" docs
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns, docs/icon.png, docs/favicon.png"
