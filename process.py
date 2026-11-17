"""Turn a recording folder (mic.m4a + system.m4a + meta.json) into transcript.md and note.md.

Usage: python process.py <recording folder>     (the Python that has mlx-whisper installed)

Transcription is local (mlx-whisper). The note is written by a command-line LLM:
the `claude` CLI if it is installed, or whatever TYNDA_NOTE_CMD names — any command that
reads a prompt on stdin and prints the answer. Without one you still get the transcript.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

os.environ["PATH"] = ":".join([
    str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", ""),
])

WHISPER_MODEL = os.environ.get("TYNDA_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
CLAUDE_MODEL = os.environ.get("TYNDA_CLAUDE_MODEL", "opus")
NOTE_CMD = os.environ.get("TYNDA_NOTE_CMD", "")
RUSSIAN = os.environ.get("TYNDA_LANG", "en") == "ru"
ME, THEM = ("Я", "Собеседник") if RUSSIAN else ("Me", "Them")

NOTE_PROMPT = """You are writing the notes of a meeting from its transcript. The transcript is automatic: \
it contains recognition mistakes, and "{me}" / "{them}" are the microphone track and the computer-audio \
track ("{them}" may be several people).

Write the notes in the language the meeting was held in, in Markdown, with no preamble:

# <a short title that says what the meeting was about>
## Summary
2–4 sentences.
## Discussed
Bullet points by topic, with specifics: numbers, names, dates.
## Decisions
## Action items
"who — what — by when"; a deadline only if one was said.
## Open questions

Translate the section headings into the meeting's language. Skip empty sections. Invent nothing: \
what is not in the transcript is not in the notes. Reply with the notes only.

Transcript:

{transcript}
"""


def log(msg):
    print(msg, flush=True)


def max_volume_db(path):
    """Peak level of the file; None if it cannot be read."""
    r = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True)
    m = re.search(r"max_volume:\s*(-?[\d.]+|-inf) dB", r.stderr)
    if not m:
        return None
    return float("-inf") if m.group(1) == "-inf" else float(m.group(1))


def norm(word):
    return re.sub(r"[^\w]", "", word.lower().replace("ё", "е"))


def transcribe(path):
    """Returns whisper segments for one track, or [] if the track is missing or silent."""
    if not path.exists() or path.stat().st_size < 2000:
        return []
    vol = max_volume_db(path)
    if vol is None or vol < -55:
        log(f"{path.name}: silent ({vol} dB), skipped")
        return []
    log(f"{path.name}: transcribing")
    import mlx_whisper
    data = mlx_whisper.transcribe(str(path), path_or_hf_repo=WHISPER_MODEL, word_timestamps=True,
                                  condition_on_previous_text=False, verbose=None)
    log(f"{path.name}: language {data.get('language')}")
    segs = []
    for s in data.get("segments", []):
        text = s.get("text", "").strip()
        # Drop what whisper itself marks as "probably not speech" (hallucinations on silence).
        if not text or s.get("no_speech_prob", 0) > 0.6:
            continue
        # A segment's own start can include leading silence; the first word's start does not.
        words = s.get("words") or []
        start = float(words[0]["start"]) if words else float(s["start"])
        segs.append({"start": start, "end": float(s["end"]), "text": text,
                     "words": [(float(w["start"]), norm(w["word"])) for w in words]})
    return segs


def drop_echo(mic, system, offset):
    """Without headphones the microphone also hears the speakers. Drop mic segments whose
    words were said on the system track at the same moment."""
    heard = [(t + offset, w) for s in system for t, w in s["words"] if w]
    kept = []
    for seg in mic:
        words = [(t, w) for t, w in seg["words"] if w]
        if len(words) >= 3:
            hits = sum(any(w == hw and abs(t - ht) < 3 for ht, hw in heard) for t, w in words)
            if hits / len(words) >= 0.6:
                continue
        kept.append(seg)
    return kept


def stamp(sec):
    sec = int(max(sec, 0))
    h, m, s = sec // 3600, sec % 3600 // 60, sec % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def build_transcript(mic, system, offset):
    lines = [dict(s, who=ME) for s in mic]
    lines += [dict(s, who=THEM, start=s["start"] + offset, end=s["end"] + offset) for s in system]
    lines.sort(key=lambda s: s["start"])
    # Glue consecutive segments of the same speaker into one paragraph.
    blocks = []
    for s in lines:
        if blocks and blocks[-1]["who"] == s["who"] and s["start"] - blocks[-1]["end"] < 20:
            blocks[-1]["text"] += " " + s["text"]
            blocks[-1]["end"] = s["end"]
        else:
            blocks.append(dict(s))
    return "\n\n".join(f"**{b['who']}** [{stamp(b['start'])}]: {b['text']}" for b in blocks)


def note_command():
    """The command that turns a prompt on stdin into a note on stdout, or None."""
    if NOTE_CMD:
        return shlex.split(NOTE_CMD)
    if shutil.which("claude"):
        return ["claude", "-p", "--model", CLAUDE_MODEL, "--tools", "", "--strict-mcp-config",
                "--no-session-persistence", "--system-prompt", "You are a careful meeting secretary."]
    return None


def write_note(cmd, transcript):
    prompt = NOTE_PROMPT.format(me=ME, them=THEM, transcript=transcript)
    r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, cwd="/tmp", timeout=900)
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError(f"{cmd[0]} failed ({r.returncode}): {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout.strip()


def main():
    d = Path(sys.argv[1]).resolve()
    meta = json.loads((d / "meta.json").read_text()) if (d / "meta.json").exists() else {}

    mic = transcribe(d / "mic.m4a")
    system = transcribe(d / "system.m4a")
    offset = float(meta.get("system_offset_sec", 0))
    mic = drop_echo(mic, system, offset)
    if not mic and not system:
        (d / "transcript.md").write_text("No speech found in the recording.\n")
        log("no speech found")
        return 1

    transcript = build_transcript(mic, system, offset)
    (d / "transcript.md").write_text(f"# {d.name}\n\n{transcript}\n")
    log("transcript.md written")

    cmd = note_command()
    if not cmd:
        log("no note: neither the claude CLI nor TYNDA_NOTE_CMD is available; the transcript is ready")
        return 0
    try:
        note = write_note(cmd, transcript)
    except Exception as e:  # the transcript is already saved; report and exit non-zero
        log(f"note failed: {e}")
        return 2
    (d / "note.md").write_text(note + f"\n\n---\n[Transcript](transcript.md) · {d.name}\n")
    log("note.md written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
