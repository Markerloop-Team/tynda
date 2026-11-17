# Contributing to Tynda

Thanks for wanting to help. Tynda is one Objective-C file, one Python file and three shell scripts, so you can read all of it in an evening.

## What Tynda must stay

1. **Nothing is saved.** No history, no audio, no text on disk. The only file is a log of timings.
2. **Nothing leaves the Mac.** No network calls after the model is downloaded, no telemetry, no accounts.
3. **Nothing to configure before the first sentence.** Hold fn, speak, get text. The two things that can be changed — the key and the languages — have defaults that work. A change that adds a setting should explain why a good default is impossible.

A pull request that breaks one of these will be declined even if the feature is nice. Open an issue first if you are not sure.

## Build and run

You need a Mac with Apple silicon, macOS 14 or newer, the Xcode Command Line Tools, and Python 3.10–3.13 or `uv`.

```bash
./install.sh      # sets up the model, builds, installs into ~/Applications, opens the setup window
./build.sh        # only builds ./Tynda.app
./uninstall.sh    # removes everything again
```

The app is signed ad hoc, so macOS treats every rebuild as a new app and asks for Microphone and Accessibility again. Batch your changes.

## Where things are

| File | What is in it |
|---|---|
| `Sources/main.m` | The app: menu bar icon, the island, microphone capture, the fn listener, pasting, the setup window |
| `dictate_server.py` | Keeps the speech model loaded and turns a WAV into text |
| `build.sh`, `install.sh`, `uninstall.sh` | Build and install without Xcode |
| `tools/make_icon.m` | Draws the icon and the menu bar mark |
| `docs/` | The landing page at tynda.markerloop.com |

## Testing without the keyboard

fn and pasting need the Accessibility permission, which is awkward in a test loop. There is a built-in rehearsal that needs only the microphone:

```bash
open -n ./Tynda.app --args --demo-dictation 6 /tmp/out.txt
```

It starts a hands-free dictation, stops after six seconds, writes the recognised text to the file and quits. Timings go to `~/Library/Logs/Tynda.log`.

The engine can be tested on its own:

```bash
printf '{"path": "/path/to/some.wav"}\n' | ~/Library/Application\ Support/Tynda/venv/bin/python dictate_server.py
```

## Pull requests

- One change per pull request, with a sentence on why.
- Say what you tested and on which Mac and macOS version. "Not tested on X" is a fine thing to write.
- Match the code around you: plain C-style Objective-C, comments that say why.
- Interface text goes through `L(@"English", @"Русский")`; if you do not speak Russian, leave the second string the same as the first and say so.

## Releases

Maintainers cut releases; contributors only add a line under *Unreleased* in `CHANGELOG.md`.

1. A release pull request moves the *Unreleased* notes into a new `## [x.y.z] — date` section and sets `VERSION`.
2. After it is merged, `tools/release.sh` on an up-to-date `main` checks that `VERSION`, the changelog and the build agree, tags `vx.y.z` and publishes the GitHub release with those notes. `tools/release.sh --dry-run` shows what it would do.

Versions follow Semantic Versioning. While Tynda is 0.x, releases are marked as pre-releases.

By contributing you agree that your work is released under the [MIT license](LICENSE).
