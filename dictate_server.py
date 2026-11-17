"""Keeps the whisper model loaded so a dictated phrase is transcribed in about a second.

Run with the mlx-whisper tool's own python. Protocol, one JSON object per line:
  stdin:  {"path": "/tmp/x.wav"}
  stdout: {"ready": true} once after warm-up, then {"text": "...", "ms": 840} per request.
"""
import json
import os
import re
import sys
import time
from pathlib import Path

os.environ["PATH"] = ":".join([
    str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", ""),
])

# The protocol owns the real stdout; anything a library prints goes to stderr.
out = os.fdopen(os.dup(1), "w")
os.dup2(2, 1)

import mlx.core as mx  # noqa: E402
import mlx_whisper  # noqa: E402
import numpy as np  # noqa: E402
from mlx_whisper.audio import N_FRAMES, N_SAMPLES, load_audio, log_mel_spectrogram, pad_or_trim  # noqa: E402
from mlx_whisper.transcribe import ModelHolder  # noqa: E402

MODEL = os.environ.get("TYNDA_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
LANGS = {"ru", "en", "kk"}
# Phrases whisper invents on silence or noise.
JUNK = re.compile(
    r"субтитр|продолжение следует|спасибо за просмотр|подписывайтесь на канал|"
    r"thanks? for watching|thank you for watching|amara\.org|dimatorzok", re.I)


def send(obj):
    out.write(json.dumps(obj, ensure_ascii=False) + "\n")
    out.flush()


# Spontaneous speech often comes back lowercase and without punctuation. A short, properly
# punctuated lead-in in the same language sets the style for the whole phrase.
PROMPTS = {
    "ru": "Так, смотри. Это обычная диктовка: с заглавными буквами, запятыми и точками. Хорошо?",
    "en": "Okay, look. This is ordinary dictation: with capital letters, commas and full stops. Right?",
    "kk": "Жарайды, қара. Бұл қарапайым диктовка: бас әріптермен, үтірлермен және нүктелермен.",
}


def detect_language(audio):
    """The most likely of our languages for the first 30 seconds."""
    model = ModelHolder.get_model(MODEL, mx.float16)
    mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    _, probs = model.detect_language(pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16))
    return max(LANGS, key=lambda l: probs.get(l, 0))


def run(audio, language):
    return mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language=language,
                                  initial_prompt=PROMPTS.get(language),
                                  condition_on_previous_text=True, verbose=None)


def transcribe(path):
    audio = load_audio(path)
    if len(audio) == 0 or float(np.abs(audio).max()) < 0.003:  # digital silence
        return ""
    try:
        language = detect_language(audio)
    except Exception:
        language = "ru"
    r = run(audio, language)
    parts = [s["text"].strip() for s in r.get("segments", []) if s.get("no_speech_prob", 0) <= 0.6]
    text = re.sub(r"\s+", " ", " ".join(p for p in parts if p)).strip()
    if JUNK.search(text) and len(text) < 80:
        return ""
    # The lead-in itself can leak into the output on near-silence.
    if any(text and text in prompt for prompt in PROMPTS.values()):
        return ""
    words = re.findall(r"\w+", text.lower())
    return "" if all(w in {"you", "thank", "thanks", "bye"} for w in words) else text


def quit_with_parent():
    """If the app is killed, don't stay behind holding 2 GB of memory."""
    import threading
    parent = os.getppid()

    def watch():
        while os.getppid() == parent:
            time.sleep(2)
        os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


quit_with_parent()
run(np.zeros(16000, dtype=np.float32), "ru")  # load the model before the first real phrase
send({"ready": True})

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    t = time.time()
    try:
        send({"text": transcribe(json.loads(line)["path"]), "ms": int((time.time() - t) * 1000)})
    except Exception as e:
        send({"error": str(e)})
