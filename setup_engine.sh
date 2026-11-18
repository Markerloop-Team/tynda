#!/bin/zsh
# Installs the speech engine for a Tynda that was dragged into Applications: Python, mlx-whisper
# and the speech model. The app runs this by itself on first launch; nothing here needs Terminal,
# git or Homebrew. Everything lands in ~/Library/Application Support/Tynda, plus the model in the
# shared Hugging Face cache.
#
# Progress goes to stdout as "STAGE <name>" lines, which the setup window turns into words.
set -euo pipefail

HERE="${0:A:h}"
SUPPORT="$HOME/Library/Application Support/Tynda"
VENV="$SUPPORT/venv"
MARK="$SUPPORT/setting-up"   # while this file exists the app does not trust the environment
MODEL="${TYNDA_WHISPER_MODEL:-mlx-community/whisper-large-v3-turbo}"

mkdir -p "$SUPPORT"
: > "$MARK"

# uv does the installing. The downloadable app carries its own copy; a build from source uses the Mac's.
if [[ -f "$HERE/uv" ]]; then
  UV="$SUPPORT/uv"
  # A setup left running by a Tynda that was quit midway still holds this file. Writing over a
  # running program makes macOS kill every later launch of it (status 137), so stop the old one
  # and put the copy in as a new file.
  pkill -f "$UV" 2>/dev/null || true
  rm -f "$UV"
  cp -f "$HERE/uv" "$UV"
  chmod +x "$UV"
  xattr -d com.apple.quarantine "$UV" 2>/dev/null || true   # it arrived inside a downloaded app
else
  export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"
  UV="$(command -v uv)" || { echo "STAGE no-uv"; exit 3; }
fi
export UV_PYTHON_INSTALL_DIR="$SUPPORT/python"   # Tynda's own Python, removed together with Tynda
export UV_NO_CACHE=1 UV_NO_PROGRESS=1

echo "STAGE python"
rm -rf "$VENV"
"$UV" venv --quiet --python 3.12 --python-preference only-managed "$VENV"

echo "STAGE packages"
"$UV" pip install --quiet --python "$VENV/bin/python" mlx-whisper

echo "STAGE model"
"$VENV/bin/python" -c 'import sys; from huggingface_hub import snapshot_download; snapshot_download(repo_id=sys.argv[1])' "$MODEL"

rm -f "$MARK"
echo "STAGE done"
