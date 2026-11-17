"""Keeps the speech model loaded so a dictated phrase turns into text in about a second.

Run with the Python that has mlx-whisper installed. Protocol, one JSON object per line:
  stdin:  {"path": "/tmp/x.wav"}
  stdout: {"ready": true} once after warm-up, then {"text": "...", "ms": 840} per request.

Nothing is kept: the app deletes the audio file as soon as the answer arrives.
"""
import json
import os
import re
import struct
import sys
import threading
import time

# The protocol owns the real stdout; anything a library prints goes to stderr.
out = os.fdopen(os.dup(1), "w")
os.dup2(2, 1)

import mlx.core as mx  # noqa: E402
import mlx_whisper  # noqa: E402
import numpy as np  # noqa: E402
from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim  # noqa: E402
from mlx_whisper.transcribe import ModelHolder  # noqa: E402

MODEL = os.environ.get("TYNDA_WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")
RATE = 16000

# The languages to listen for, chosen in the setup window. Left to itself the model sometimes takes a
# cough or a short word for a sentence in a language nobody in the room speaks; a short list stops that.
# An empty list means "any language".
LANGS = [c for c in os.environ.get("TYNDA_LANGS", "en,ru,kk").split(",") if c]

# Spontaneous speech often comes back lowercase and unpunctuated. A short, properly punctuated
# lead-in sets the style. Where there is none, the model's own habits apply.
STYLE = {
    "en": "Okay, look. This is ordinary dictation: with capital letters, commas and full stops. Right?",
    "ru": "Так, смотри. Это обычная диктовка: с заглавными буквами, запятыми и точками. Хорошо?",
    "kk": "Жарайды, қара. Бұл қарапайым диктовка: бас әріптермен, үтірлермен және нүктелермен.",
    "es": "Bien, mira. Esto es un dictado normal: con mayúsculas, comas y puntos. ¿De acuerdo?",
    "de": "Gut, schau mal. Das ist ein ganz normales Diktat: mit Großbuchstaben, Kommas und Punkten. In Ordnung?",
    "fr": "Bon, écoute. C'est une dictée ordinaire : avec des majuscules, des virgules et des points. D'accord ?",
}

# Phrases the model invents on silence or noise.
JUNK = re.compile(
    r"субтитр|продолжение следует|спасибо за просмотр|подписывайтесь на канал|"
    r"thanks? for watching|thank you for watching|amara\.org|dimatorzok", re.I)


def send(obj):
    out.write(json.dumps(obj, ensure_ascii=False) + "\n")
    out.flush()


def read_wav(path):
    """The app writes plain 32-bit float mono WAV. Returns it at 16 kHz."""
    data = open(path, "rb").read()
    rate, audio, pos = RATE, np.zeros(0, dtype=np.float32), 12
    while pos + 8 <= len(data):  # walk the RIFF chunks: "fmt " has the rate, "data" the samples
        name, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if name == b"fmt ":
            rate = struct.unpack_from("<I", body, 4)[0]
        elif name == b"data":
            audio = np.frombuffer(body[:len(body) // 4 * 4], dtype="<f4").astype(np.float32)
        pos += 8 + size + (size & 1)
    if rate == RATE or len(audio) == 0:
        return audio
    try:
        from math import gcd
        from scipy.signal import resample_poly
        g = gcd(RATE, rate)
        return resample_poly(audio, RATE // g, rate // g).astype(np.float32)
    except ImportError:  # crude but serviceable: average neighbours, then pick points
        step = rate / RATE
        kernel = max(1, int(step))
        smooth = np.convolve(audio, np.ones(kernel) / kernel, mode="same")
        return np.interp(np.arange(0, len(audio), step), np.arange(len(audio)), smooth).astype(np.float32)


def spoken_language(audio):
    model = ModelHolder.get_model(MODEL, mx.float16)
    mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    _, probs = model.detect_language(pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16))
    return max(LANGS or probs, key=lambda c: probs.get(c, 0))


def run(audio, language):
    return mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language=language,
                                  initial_prompt=STYLE.get(language),
                                  condition_on_previous_text=True, verbose=None)


def transcribe(path):
    audio = read_wav(path)
    if len(audio) == 0 or float(np.abs(audio).max()) < 0.003:  # digital silence
        return ""
    try:
        language = spoken_language(audio)
    except Exception:
        language = None  # let the model decide on its own
    r = run(audio, language)
    parts = [s["text"].strip() for s in r.get("segments", []) if s.get("no_speech_prob", 0) <= 0.6]
    text = re.sub(r"\s+", " ", " ".join(p for p in parts if p)).strip()
    if JUNK.search(text) and len(text) < 80:
        return ""
    if any(text and text in lead_in for lead_in in STYLE.values()):  # the lead-in leaking out on near-silence
        return ""
    words = re.findall(r"\w+", text.lower())
    return "" if all(w in {"you", "thank", "thanks", "bye"} for w in words) else text


def quit_with_parent():
    """If the app is killed, don't stay behind holding 2 GB of memory."""
    parent = os.getppid()

    def watch():
        while os.getppid() == parent:
            time.sleep(2)
        os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


quit_with_parent()
run(np.zeros(RATE, dtype=np.float32), "en")  # load the model before the first real phrase
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
