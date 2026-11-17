# Changelog

Every release of Tynda, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). While Tynda is at 0.x, a minor version may change
behaviour; the notes always say so.

## [Unreleased]

## [0.1.0] — 2026-11-18

The first public release. Early alpha: it works on its author's Mac and has not met many others yet.

### Added

- **Dictation with one key.** Hold fn and talk; let go and the text is typed where the cursor is.
- **Hands-free.** Double-tap the key, talk as long as you like, press it again to finish. A recording that was
  forgotten stops by itself after 45 seconds of silence and leaves the text on the clipboard.
- **Esc** throws the recording away.
- **Choose the key.** fn by default; in the setup window you can pick Option, Control, the right Command or an
  F-key instead, in case fn is taken.
- **The island.** A small black pill with a live waveform at the top of the screen while Tynda listens. It never
  takes focus.
- **On-device speech recognition.** Whisper large-v3-turbo through Apple MLX, kept loaded so a short phrase
  takes about a second and a half. No language to choose: the model works out what it hears.
- **Nothing is saved.** No history and no audio on disk; the only file is a log of timings.
- **Setup window.** Walks through the microphone, Accessibility, the dictation key and the speech model with a
  live status for each, has a field to try the first phrase in, and a switch to start Tynda at login.
- **Install and uninstall scripts.** `./install.sh` sets up the model, builds the app with `clang` and opens it;
  `./uninstall.sh` removes it again.

### Known limits

- Not signed or notarised: installed from source, and macOS asks for the permissions again after every rebuild.
- Apple silicon and macOS 14 or newer only.

[Unreleased]: https://github.com/Markerloop-Team/tynda/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.1.0
