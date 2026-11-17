#!/bin/zsh
# Removes Tynda from this Mac.
#
#   ./uninstall.sh          the app, its settings, its permissions and the speech model environment
#   ./uninstall.sh --all    also the downloaded speech model (1.6 GB) — the next install downloads it again
set -euo pipefail

APP="$HOME/Applications/Tynda.app"
SUPPORT="$HOME/Library/Application Support/Tynda"
MODEL_CACHE="$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo"
LOG="$HOME/Library/Logs/Tynda.log"

say_step() { print -P "%B==> $1%b"; }

say_step "Quitting Tynda"
pkill -x Tynda 2>/dev/null || true
sleep 1

say_step "Forgetting permissions (microphone, accessibility)"
tccutil reset All app.tynda.mac >/dev/null 2>&1 || true

say_step "Removing the app, its settings and the speech model environment"
[[ -d "$APP" ]] && rm -rf "$APP"
[[ -d "$SUPPORT" ]] && rm -rf "$SUPPORT"
[[ -f "$LOG" ]] && rm -f "$LOG"
defaults delete app.tynda.mac >/dev/null 2>&1 || true

if [[ "${1:-}" == "--all" ]]; then
  say_step "Removing the downloaded speech model"
  [[ -d "$MODEL_CACHE" ]] && rm -rf "$MODEL_CACHE"
fi

echo
echo "Tynda is removed."
[[ -d "$HOME/Tynda" ]] && echo "An early version kept files in ~/Tynda. Tynda no longer uses that folder — delete it yourself if you do not need them."
[[ "${1:-}" != "--all" && -d "$MODEL_CACHE" ]] && echo "The speech model (1.6 GB) was kept so that a reinstall is quick. Remove it too with: ./uninstall.sh --all"
exit 0
