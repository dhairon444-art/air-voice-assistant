"""Measure voice engines next to the brain: load time, RAM, time to first audio, real-time factor.

    python voice_test.py --out voices.json [--brain mlx-community/Qwen3-4B-Instruct-2507-4bit]

Loads the brain first (as in the app), then Kokoro and each voice pack in turn. For cloning, a 15 s
reference clip is made with Kokoro (a synthetic voice, so no rights issue) and MOSS-TTS-Nano clones it.
Writes a WAV sample per voice next to --out for listening. GPU-heavy: only in an agreed window.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))

SENTENCES = [
    "Hi, I'm Aria. Here's what's on your plate today.",
    "You have three reminders due, and the dentist is on Tuesday at three in the afternoon.",
    "Want me to move the invoice to tomorrow morning, or keep it where it is?",
]


def write_wav(path: Path, pcm: np.ndarray, rate: int = 24000) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--brain", default="mlx-community/Qwen3-4B-Instruct-2507-4bit")
    a = p.parse_args()
    out = Path(a.out)
    import mlx.core as mx
    from mlx_lm import load as load_lm
    from mlx_audio.tts.utils import load_model
    from voice_packs import PackVoices

    gb = lambda: round(mx.get_active_memory() / 1e9, 2)
    lm, _ = load_lm(a.brain)
    base = gb()
    rows = []

    def measure(name: str, gen, load_s: float, mem_before: float):
        first, total_audio, t0 = None, 0.0, time.monotonic()
        chunks = []
        for i, s in enumerate(SENTENCES):
            ts = time.monotonic()
            for pcm in gen(s):
                if i == 0 and first is None:
                    first = time.monotonic() - ts
                chunks.append(pcm)
                total_audio += pcm.shape[0] / 24000
        synth = time.monotonic() - t0
        audio = np.concatenate(chunks) if chunks else np.zeros(1)
        wav = out.with_name(out.stem + "-" + name.replace(":", "_").replace(" ", "_") + ".wav")
        write_wav(wav, audio)
        row = {"voice": name, "load_s": round(load_s, 1), "ram_gb": round(gb() - mem_before, 2),
               "first_audio_s": round(first or 0, 2), "rtf": round(synth / max(total_audio, 1e-3), 3),
               "audio_s": round(total_audio, 1), "peak_gb": round(mx.get_peak_memory() / 1e9, 2), "sample": str(wav)}
        rows.append(row)
        print(json.dumps(row), flush=True)

    # Kokoro (the current voice)
    t = time.time(); m0 = gb()
    kok = load_model("mlx-community/Kokoro-82M-bf16")
    for _ in kok.generate("Hello there.", voice="af_heart", lang_code="a"):
        pass
    measure("kokoro:af_heart", lambda s: (np.array(r.audio).reshape(-1) for r in kok.generate(s, voice="af_heart", lang_code="a")),
            time.time() - t, m0)

    # A reference clip for cloning, made with Kokoro (synthetic).
    support = Path(tempfile.mkdtemp(prefix="air-voice-test-"))
    (support / "voices").mkdir()
    ref = np.concatenate([np.array(r.audio).reshape(-1) for r in kok.generate(
        "This is a short reference recording for a test voice. It talks about the weather, a cup of coffee, "
        "and a walk in the park on a quiet Sunday morning, at an easy and natural pace.", voice="bf_emma", lang_code="b")])
    write_wav(support / "voices" / "testclone.wav", ref)
    (support / "voices" / "testclone.json").write_text(json.dumps({"consent": True, "source": "synthetic Kokoro bf_emma"}))
    del kok
    mx.clear_cache()

    packs = PackVoices(support, emit=lambda k, m: print(k, m, flush=True))
    for v in ("melo:EN-US", "melo:EN-BR", "soprano", "clone:testclone"):
        try:
            m0 = gb()
            mx.reset_peak_memory()
            t = time.time()
            packs.ensure(v)
            for _ in packs.generate(v, "Hello there."):
                pass
            measure(v, lambda s, v=v: packs.generate(v, s), time.time() - t, m0)
        except Exception as exc:
            print(json.dumps({"voice": v, "error": f"{type(exc).__name__}: {exc}"[:300]}), flush=True)
            rows.append({"voice": v, "error": f"{type(exc).__name__}: {exc}"[:300]})
    out.write_text(json.dumps({"brain": a.brain, "brain_gb": base, "rows": rows}, indent=1))


if __name__ == "__main__":
    main()
