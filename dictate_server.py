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
# The exact version of the model that setup_engine.sh downloads. Loading it by its folder keeps the engine
# from fetching a newer one by itself. A Mac set up before the version was fixed, or somebody's own model,
# has no such folder: then the model is loaded by name, as before.
MODEL_REVISION = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
if "TYNDA_WHISPER_MODEL" not in os.environ:
    try:
        from huggingface_hub import snapshot_download
        MODEL = snapshot_download(repo_id=MODEL, revision=MODEL_REVISION, local_files_only=True)
    except Exception:
        pass
RATE = 16000

# The languages to listen for, chosen in the setup window. Left to itself the model sometimes takes a
# cough or a short word for a sentence in a language nobody in the room speaks; a short list stops that.
# An empty list means "any language".
LANGS = [c for c in os.environ.get("TYNDA_LANGS", "").split(",") if c]

# The user's own words — names, brands, terms — one per line. The model is shown them before every
# phrase, the way it is shown the text that came before, which is how it learns their spelling.
# The model looks at about 220 tokens of such text and prefers the end of it, so the list is kept
# short and is placed before the style lead-in.
WORDS = [w.strip() for w in os.environ.get("TYNDA_WORDS", "").split("\n") if w.strip()]
GLOSSARY = ""
for word in WORDS:
    if len(GLOSSARY) + len(word) > 500:
        break
    GLOSSARY += (", " if GLOSSARY else "") + word
if GLOSSARY:
    GLOSSARY += "."

# Spontaneous speech often comes back lowercase and unpunctuated. A short, properly punctuated
# lead-in sets the style. Where there is none, the model's own habits apply.
STYLE = {
    "en": "Okay, look. This is ordinary dictation: with capital letters, commas and full stops. Right?",
    "ru": "Так, смотри. Это обычная диктовка: с заглавными буквами, запятыми и точками. Хорошо?",
    # No Kazakh lead-in: on short Kazakh phrases the model wrote the lead-in back instead of the speech,
    # and it punctuates Kazakh well enough without one.
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


def spoken_languages(clips):
    """The language of each clip, among the chosen ones. One pass of the model for all of them."""
    model = ModelHolder.get_model(MODEL, mx.float16)
    mels = [pad_or_trim(log_mel_spectrogram(c, n_mels=model.dims.n_mels, padding=N_SAMPLES), N_FRAMES, axis=-2)
            for c in clips]
    _, probs = model.detect_language(mx.stack(mels).astype(mx.float16))
    return [max(LANGS or p, key=lambda c: score(p, c)) for p in probs]


# The model knows little Kazakh and often hears it as Turkish or Azerbaijani; Russian with an accent may
# pass for Ukrainian. A relative nobody chose counts for the chosen language of its family.
FAMILIES = [{"kk", "tr", "az", "uz", "tk", "tt", "ba"}, {"ru", "uk", "be"}]


def score(probs, lang):
    family = next((f for f in FAMILIES if lang in f), {lang})
    return sum(probs.get(c, 0) for c in family if c == lang or c not in LANGS)


def spoken_language(audio):
    return spoken_languages([audio])[0]


def run(audio, language, before=""):
    """before: what was said just before, in another language. It carries capitals and punctuation
    across the seam; the language itself is fixed by `language`, so a Russian tail doesn't turn a
    Kazakh piece Russian."""
    lead_in = " ".join(part for part in (GLOSSARY, STYLE.get(language), before[-120:]) if part) or None
    return mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language=language,
                                  initial_prompt=lead_in,
                                  condition_on_previous_text=True, verbose=None)


def pieces(audio, pause=0.5, shortest=0.6):
    """Cuts the phrase where the speaker stopped for at least `pause` seconds. A piece shorter than
    `shortest` is glued to the one before it: a single short word says little about its language."""
    win = RATE // 50  # 20 ms
    peaks = np.abs(audio[:len(audio) // win * win]).reshape(-1, win).max(axis=1)
    loud = peaks > max(0.01, float(peaks.max()) * 0.05)
    spans, start, quiet = [], None, 0
    for i, on in enumerate(loud):
        if on:
            start = i if start is None else start
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet * win >= pause * RATE:
                spans.append([start, i - quiet + 1])
                start, quiet = None, 0
    if start is not None:
        spans.append([start, len(loud)])
    merged = []
    for s, e in spans:
        if merged and (e - s) * win < shortest * RATE:
            merged[-1][1] = e
        elif merged and (merged[-1][1] - merged[-1][0]) * win < shortest * RATE:
            merged[-1][1] = e
        else:
            merged.append([s, e])
    pad = RATE // 10
    return [audio[max(0, s * win - pad):e * win + pad] for s, e in merged]


def by_language(audio):
    """[(language, audio)]: one entry when the phrase is in one language, several when it switches
    between the chosen languages at pauses.
    Each run of pieces in one language is put back together, so a phrase in one language costs one
    quick look per piece and is then read whole, as before."""
    parts = pieces(audio) if len(LANGS) > 1 else []
    if len(parts) < 2:
        return [(spoken_language(audio), audio)]
    runs = []
    for part, lang in zip(parts, spoken_languages(parts)):
        if runs and runs[-1][0] == lang:
            runs[-1][1].append(part)
        else:
            runs.append((lang, [part]))
    if len(runs) < 2:
        return [(runs[0][0], audio)]
    gap = np.zeros(RATE // 5, dtype=np.float32)
    return [(lang, np.concatenate([x for p in ps for x in (p, gap)])) for lang, ps in runs]


def clean(r):
    parts = [s["text"].strip() for s in r.get("segments", []) if s.get("no_speech_prob", 0) <= 0.6]
    text = re.sub(r"\s+", " ", " ".join(p for p in parts if p)).strip()
    if JUNK.search(text) and len(text) < 80:
        return ""
    if any(text and text in lead_in for lead_in in [*STYLE.values(), GLOSSARY]):  # the lead-in leaking out on near-silence
        return ""
    words = re.findall(r"\w+", text.lower())
    return "" if all(w in {"you", "thank", "thanks", "bye"} for w in words) else text


def transcribe(path):
    audio = read_wav(path)
    if len(audio) == 0 or float(np.abs(audio).max()) < 0.003:  # digital silence
        return ""
    try:
        runs = by_language(audio)
    except Exception:
        runs = [(None, audio)]  # let the model decide on its own
    text = ""
    for lang, part in runs:  # "раз, два, три, бір, екі, үш, one, two, three": each language read as itself
        piece = clean(run(part, lang, text))
        if text.endswith((".", "!", "?")):
            piece = piece[:1].upper() + piece[1:]
        text = (text + " " + piece).strip()
    return text


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
