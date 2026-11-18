#!/bin/zsh
# Builds dist/Tynda-<version>.dmg: the app, ready to drag into Applications.
# Unlike a build from source, this app carries uv and installs its speech engine by itself.
#
#   tools/make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
UV_VERSION=0.11.6
UV_SHA256=4b69a4e366ec38cd5f305707de95e12951181c448679a00dce2a78868dfc9f5b
OUT="dist/Tynda-$VERSION.dmg"

say_step() { print -P "%B==> $1%b"; }

say_step "uv $UV_VERSION (travels inside the app)"
mkdir -p vendor dist
if ! vendor/uv --version 2>/dev/null | grep -q " $UV_VERSION "; then
  TMP="$(mktemp -d)"
  curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" -o "$TMP/uv.tar.gz"
  echo "$UV_SHA256  $TMP/uv.tar.gz" | shasum -a 256 -c -
  tar -xzf "$TMP/uv.tar.gz" -C "$TMP"
  cp "$TMP/uv-aarch64-apple-darwin/uv" vendor/uv
  rm -rf "$TMP"
fi

say_step "Building the app"
./build.sh

say_step "Drawing the window picture"
WORK="$(mktemp -d)"
clang -fobjc-arc -O2 -framework Cocoa tools/make_dmg_background.m -o "$WORK/make_bg"
"$WORK/make_bg" "$WORK/bg.png" 1
"$WORK/make_bg" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff" 2>/dev/null

say_step "Packing $OUT"
rm -f "$OUT"
vendor/uv tool run --quiet dmgbuild@2.0.0 -s tools/dmg_settings.py -D app=Tynda.app -D background="$WORK/background.tiff" "Tynda" "$OUT"
rm -rf "$WORK" Tynda.app   # leave one copy on the Mac, or Spotlight and Launchpad show Tynda twice

echo
echo "Built $PWD/$OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
shasum -a 256 "$OUT"
