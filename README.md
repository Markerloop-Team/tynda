<img src="docs/icon.png" width="96" alt="Tynda icon">

# Tynda

**Hold fn. Speak. It types.** A small, free, open-source Mac app that lets you talk instead of typing. Your voice is turned into text on your own Mac and typed wherever your cursor is.

*Tynda* (тыңда) is Kazakh for "listen".

> **Early alpha.** Tynda is new and has been used on one Mac. It is installed from source, there is no signed download yet. Expect rough edges and tell us about them.

## How it works

- **Hold fn** and talk. Let go — the text appears where your cursor is, about a second later.
- **Double-tap fn** for hands-free. Talk as long as you like, press fn again to finish.
- **Esc** throws it away.

A small black island with a live waveform shows at the top of the screen while Tynda listens. That is the whole app: no window to keep open, no account, nothing to configure. You speak the way you normally speak and get what you said.

## Nothing is saved, nothing leaves your Mac

- Your voice is recognised on your Mac by [Whisper large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) running through Apple's [MLX](https://github.com/ml-explore/mlx). Once the model is downloaded, Tynda works with the network off.
- The audio lives for a second in a temporary file and is deleted as soon as it becomes text.
- The text is typed into your app and is not written anywhere else. There is no history.
- No account, no telemetry, no server.

## Requirements

| | |
|---|---|
| Mac | Apple silicon (M1 or newer). Intel Macs are not supported — the speech model does not run on them. |
| macOS | 14 Sonoma or newer |
| Memory | 8 GB minimum, 16 GB recommended. The model stays loaded (about 2 GB). |
| Disk | about 3 GB (model 1.6 GB + Python packages) |
| Tools | Xcode Command Line Tools, and Python 3.10–3.13 or [uv](https://docs.astral.sh/uv/) |
| Keyboard | The fn / 🌐 key set to "Do Nothing" in System Settings → Keyboard |

## Install

```bash
git clone https://github.com/toleberdyyeva/tynda.git
cd tynda
./install.sh
```

The script checks your Mac, downloads the speech model, builds the app and puts it into `~/Applications`. It takes a few minutes the first time, mostly the download.

When it finishes, a setup window opens and walks you through the rest, with a live check mark for each step:

1. **Microphone** — to hear you.
2. **Accessibility** — to notice the fn key and to type the text for you.
3. **The fn key** — it has to be free ("Do Nothing" in Keyboard settings).
4. **Speech model** — loads in a few seconds.

Then it gives you a text field to try your first dictation in. You can open this window again any time: Tynda icon in the menu bar → *Setup…*, or just open Tynda again from Applications.

To update: `git pull && ./install.sh`. Because the app is not signed with an Apple Developer ID, macOS treats each new build as a new app and asks for the permissions again.

## Uninstall

```bash
./uninstall.sh          # the app, its settings, permissions and Python environment
./uninstall.sh --all    # also the downloaded speech model (1.6 GB)
```

## How it is built

- `Sources/main.m` — the whole app in one Objective-C file: the menu bar icon, the island, microphone capture (AVAudioEngine), the fn listener (CGEventTap), pasting, and the setup window.
- `dictate_server.py` — keeps the speech model loaded so a phrase takes about a second instead of five.
- `build.sh` / `install.sh` / `uninstall.sh` — no Xcode project; `clang` is enough.
- `tools/make_icon.m` — draws the icon; `tools/make_icon.sh` regenerates the image files.

The only file Tynda writes is a diagnostics log, `~/Library/Logs/Tynda.log`. It records events and timings ("recorded 2.5s", "23 characters in 1.4s") and never what you said.

## Known limits

- Not signed or notarised: source install only, permissions reset on every rebuild.
- The text is pasted through the clipboard (your clipboard is restored half a second later).
- The hotkey is fixed to fn.
- If the menu bar is full, macOS may hide the Tynda icon. Dictation still works; open Tynda again from Applications to get to the setup window.
- Tested on macOS 26 only.

## License

[MIT](LICENSE)
