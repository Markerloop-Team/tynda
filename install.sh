#!/bin/zsh
# Installs Tynda from source: checks the Mac, sets up the speech model, builds the app
# and puts it into ~/Applications. Safe to run again — it updates what is there.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/Tynda"
VENV="$SUPPORT/venv"
DEST="$HOME/Applications"
MODEL="${TYNDA_WHISPER_MODEL:-mlx-community/whisper-large-v3-turbo}"

say_step() { print -P "\n%B==> $1%b"; }
fail() { print -P "\n%F{red}%B$1%b%f" >&2; exit 1; }

say_step "Checking this Mac"
[[ "$(uname -s)" == "Darwin" ]] || fail "Tynda runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Tynda needs a Mac with Apple silicon (M1 or newer). The speech model does not run on Intel Macs."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( OS_MAJOR >= 14 )) || fail "Tynda needs macOS 14 or newer. This Mac runs $(sw_vers -productVersion)."
xcrun --find clang >/dev/null 2>&1 || fail "The Xcode Command Line Tools are missing. Run:  xcode-select --install  — then run this script again."
echo "macOS $(sw_vers -productVersion), Apple silicon, compiler found."

say_step "Checking ffmpeg"
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
if ! command -v ffmpeg >/dev/null; then
  command -v brew >/dev/null || fail "ffmpeg is missing and Homebrew is not installed. Install ffmpeg (https://brew.sh, then: brew install ffmpeg) and run this script again."
  brew install ffmpeg
fi
echo "ffmpeg: $(command -v ffmpeg)"

say_step "Setting up the speech model environment"
mkdir -p "$SUPPORT"
if [[ ! -x "$VENV/bin/python" ]]; then
  if command -v uv >/dev/null; then
    uv venv --python 3.12 "$VENV"
  else
    PY=""
    for c in python3.13 python3.12 python3.11 python3.10; do
      if command -v "$c" >/dev/null; then PY="$c"; break; fi
    done
    [[ -n "$PY" ]] || fail "Python 3.10–3.13 is missing. Run:  brew install python@3.12  — then run this script again."
    "$PY" -m venv "$VENV"
  fi
fi
if command -v uv >/dev/null; then
  uv pip install --python "$VENV/bin/python" --upgrade mlx-whisper
else
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  "$VENV/bin/python" -m pip install --upgrade mlx-whisper
fi

say_step "Downloading the speech model (about 1.6 GB, only the first time)"
TYNDA_MODEL="$MODEL" "$VENV/bin/python" - <<'EOF'
import os
import numpy as np
import mlx_whisper
mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=os.environ["TYNDA_MODEL"], language="en")
print("The model is ready.")
EOF

say_step "Building Tynda"
./build.sh

say_step "Installing into $DEST"
mkdir -p "$DEST"
pkill -x Tynda 2>/dev/null || true
rm -rf "$DEST/Tynda.app"
cp -R Tynda.app "$DEST/Tynda.app"
# A rebuild is a new app for macOS: forget the stale permission so it asks again cleanly.
tccutil reset Accessibility app.tynda.mac >/dev/null 2>&1 || true
open "$DEST/Tynda.app"

print -P "\n%BTynda is running — its icon (a small speech bubble) is in the menu bar.%b"
cat <<EOF

A setup window has opened. It walks you through the last steps:
the microphone, Accessibility, the fn key — and lets you try your first dictation.

Recordings and dictation history live in ~/Tynda.
To remove Tynda later: ./uninstall.sh
EOF
