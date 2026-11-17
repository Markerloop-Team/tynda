# Tynda

**Hold fn. Speak. It types.** Free, open-source voice dictation and meeting notes for the Mac. Speech is recognised on your own machine.

*Tynda* (тыңда) is Kazakh for "listen".

> **Early alpha.** Tynda was built in a day and has been used on one Mac. It is installed from source, there is no signed download yet. Expect rough edges and tell us about them.

## What it does

**Dictation, anywhere you can type**

- **Hold fn** and talk. Let go — the text appears where your cursor is, about a second later.
- **Double-tap fn** for hands-free. Talk as long as you like, press fn again to finish.
- **Esc** throws the recording away.

A small black island with a live waveform shows at the top of the screen while Tynda listens.

**Meeting notes**

Click ◉ in the menu bar → *Record meeting*. Tynda records your microphone and the computer's sound as two separate tracks, so the transcript knows who is *Me* and who is *Them* — with no bot joining the call. When you stop, you get a transcript and, if you have a command-line LLM, a written summary with decisions and action items.

## Privacy

- Audio never leaves your Mac. Speech recognition is [Whisper large-v3-turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo) running locally through Apple's [MLX](https://github.com/ml-explore/mlx).
- Dictation is fully offline once the model is downloaded.
- Meeting **summaries** are the one exception: the transcript text is sent to the LLM you choose (see below). No LLM, no upload — you still get the transcript.
- Tynda has no account, no telemetry and no server.

## Requirements

| | |
|---|---|
| Mac | Apple silicon (M1 or newer). Intel Macs are not supported — MLX does not run on them. |
| macOS | 14 Sonoma or newer |
| Memory | 8 GB minimum, 16 GB recommended. The model stays loaded (about 2 GB). |
| Disk | about 3 GB (model 1.6 GB + Python packages) |
| Tools | Xcode Command Line Tools, [Homebrew](https://brew.sh) (for ffmpeg), Python 3.10–3.13 or [uv](https://docs.astral.sh/uv/) |
| Keyboard | The fn / 🌐 key set to "Do Nothing" in System Settings → Keyboard |

## Install

```bash
git clone https://github.com/toleberdyyeva/tynda.git
cd tynda
./install.sh
```

The script checks your Mac, installs the speech model into `~/Library/Application Support/Tynda`, builds the app and puts it into `~/Applications`. It takes a few minutes the first time, mostly the model download.

Then grant three permissions when macOS asks:

1. **Microphone** — to hear you.
2. **Accessibility** — to notice the fn key and to type the text for you.
3. **Screen & System Audio Recording** — only for meetings, to record the other side of the call.

To update: `git pull && ./install.sh`. Because the app is not signed with an Apple Developer ID, macOS treats each new build as a new app and asks for the permissions again.

## Meeting summaries

After a meeting Tynda looks for a command-line LLM to write the summary:

- [Claude Code](https://claude.com/claude-code) (`claude`) is used automatically if it is installed.
- Anything else that reads a prompt on stdin and prints an answer works too:

```bash
defaults write app.tynda.mac noteCommand "ollama run llama3.2"
```

## Where things are

| | |
|---|---|
| Recordings, transcripts, notes | `~/Tynda/<date_time>/` |
| Dictation history | `~/Tynda/dictation.md` |
| Diagnostics log | `~/Library/Logs/Tynda.log` |
| Speech model environment | `~/Library/Application Support/Tynda/venv` |

Settings are plain `defaults`:

```bash
defaults write app.tynda.mac notesDir ~/Documents/Meetings   # another folder for recordings
defaults write app.tynda.mac python /path/to/python          # a Python that already has mlx-whisper
```

## How it is built

- `Sources/main.m` — the whole app in one Objective-C file: menu bar item, the island, microphone capture (AVAudioEngine), system audio capture (ScreenCaptureKit), the fn listener (CGEventTap) and pasting.
- `dictate_server.py` — keeps Whisper loaded so a phrase takes about a second instead of five.
- `process.py` — turns a meeting recording into a transcript and a note.
- `build.sh` / `install.sh` — no Xcode project; `clang` is enough.

Languages: Tynda detects Russian, English and Kazakh per phrase. Add yours in `LANGS` and `PROMPTS` at the top of `dictate_server.py`.

## Known limits

- Not signed or notarised: source install only, permissions reset on every rebuild.
- Dictated text is pasted through the clipboard (your clipboard is restored half a second later).
- No settings window, the hotkey is fixed to fn.
- Without headphones the microphone hears the other side too; Tynda removes most of that echo from the transcript, not all.
- Tested on macOS 26 only.

## Recording other people

Tynda records everyone on the call. In many places you need their consent first. Tell people you are recording.

## License

[MIT](LICENSE)
