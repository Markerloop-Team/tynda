# Changelog

Every release of Tynda, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/). While Tynda is at 0.x, a minor version may change
behaviour; the notes always say so.

## [Unreleased]

## [0.4.1] — 2026-11-18

### Changed

- **A failed setup says why.** The setup window used to answer every failure of the speech-engine setup
  with "Check the internet connection". It now names what it can tell: which site did not answer
  (github.com, pypi.org or huggingface.co), that the disk is full, that macOS stopped the setup, or the
  step it stopped at.

## [0.4.0] — 2026-11-18

### Added

- **Tynda updates itself.** When a new version is out, the line in the menu now says "update": one click,
  and Tynda downloads the new version, checks it against the checksum of the release, puts it in place of
  the old one and starts again. No browser, no dragging, no Open Anyway. If that is not possible — Tynda sits
  in a folder it may not write to, or the download does not check out — the release page opens, as before.
  Nothing is downloaded without the click. This works from 0.4.0 on: an older Tynda still has to be
  replaced by hand once.

### Known limits

- macOS still asks for the Accessibility permission again after every update, because the app is not
  signed with an Apple Developer ID.

## [0.3.1] — 2026-11-18

### Fixed

- **Setup that could never finish.** If Tynda was quit or restarted while it was still installing its speech
  engine, every later attempt stopped within a second with "Check the internet connection and try again",
  whatever the connection was. The unfinished setup kept running in the background, and the new one wrote
  its installer over the running copy, after which macOS refused to start it. Setup now stops the leftover
  one first and starts clean. If you are stuck on 0.3.0: install 0.3.1 over it and open Tynda again.

## [0.3.0] — 2026-11-18

### Added

- **A download.** `Tynda-0.3.0.dmg` on the release page: open it, drag Tynda into Applications. No git,
  Homebrew or Terminal needed. The app is still not signed with an Apple Developer ID, so the first time
  macOS wants a click on Open Anyway in System Settings → Privacy & Security.
- **Tynda installs its own speech engine.** A downloaded Tynda fetches Python, the engine and the model on
  first launch — about 3 GB, a few minutes — and the Speech model row in the setup window shows how far it
  is, with a Try again button if the internet drops.
- **Update notice.** Once a day Tynda asks GitHub for the number of the newest release and, if there is one,
  shows a line in its menu that opens the download page. Nothing about you is sent, nothing is installed
  without a click. Switch it off with `defaults write app.tynda.mac checkForUpdates -bool NO`.
- **Report a problem** in the menu opens a new issue on GitHub.
- `tools/make_dmg.sh` builds the disk image; `tools/release.sh` attaches it to the release.

### Changed

- After an update Tynda asks macOS to forget its old Accessibility entry, so System Settings no longer shows
  the permission as switched on while it does not work.
- `uninstall.sh` also removes a Tynda that was dragged into `/Applications`.

## [0.2.1] — 2026-11-18

### Changed

- Kazakh is in the default list of languages, next to the languages of your keyboard layouts. If you do not
  need it, untick it in the setup window; a list you have already edited stays as it is.

## [0.2.0] — 2026-11-18

### Added

- **My words.** A list of names, brands and terms in the setup window, up to 100. The speech model is shown it
  before every phrase and spells those words your way more often. It is a hint: it helps most with names in
  the language they are written in, and it does not work every time.
- **The menu bar icon shows the state.** The wave means ready; dots filling in mean the speech model is
  loading; an exclamation mark means the setup needs you. The first line of the menu says the same in words.
- **A real loading indicator** for the speech model in the setup window, instead of a still grey ring.

### Changed

- **Default languages come from your keyboard layouts** instead of a fixed English, Russian and Kazakh. If you
  have already edited the list, it stays as it is.
- The setup window is more compact: the icon sits beside the title, so six steps fit a 13-inch screen.

### Fixed

- After `./install.sh` the Mac showed Tynda twice in Spotlight and Launchpad: the build left a second copy in
  the source folder. The installer now removes it.

## [0.1.1] — 2026-11-18

### Fixed

- `./uninstall.sh` failed with "permission denied": the script was published without its executable flag.
  The build check now refuses a script that cannot be run.

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
  takes about a second and a half.
- **Languages.** English, Russian and Kazakh out of the box; add or remove languages in the setup window. Tynda
  only considers the languages on the list, which keeps stray sounds from turning into text in a language you
  do not speak.
- **Nothing is saved.** No history and no audio on disk; the only file is a log of timings.
- **Setup window.** Walks through the microphone, Accessibility, the dictation key, the languages and the speech model with a
  live status for each, has a field to try the first phrase in, and a switch to start Tynda at login.
- **Install and uninstall scripts.** `./install.sh` sets up the model, builds the app with `clang` and opens it;
  `./uninstall.sh` removes it again.

### Known limits

- Not signed or notarised: installed from source, and macOS asks for the permissions again after every rebuild.
- Apple silicon and macOS 14 or newer only.

[Unreleased]: https://github.com/Markerloop-Team/tynda/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.4.1
[0.4.0]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.4.0
[0.3.1]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.3.1
[0.3.0]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.3.0
[0.2.1]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.2.1
[0.2.0]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.2.0
[0.1.1]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.1.1
[0.1.0]: https://github.com/Markerloop-Team/tynda/releases/tag/v0.1.0
