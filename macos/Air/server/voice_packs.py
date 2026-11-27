"""Voice packs: other on-device TTS engines next to Kokoro (all through mlx-audio).

    melo:EN-US / melo:EN-BR / melo:EN_INDIA / melo:EN-AU   MeloTTS English (44.1 kHz)
    soprano                                               Soprano 1.1 80M (32 kHz, one voice)
    clone:<name>                                          MOSS-TTS-Nano with a reference clip (48 kHz)

Clone voices are made in the app from a 10-30 s clip the owner has the right to use; the clip and its
consent record live in Air's support folder (voices/<name>.wav + .json) and never leave the Mac.
Each pack loads when one of its voices is chosen; only one pack is kept loaded. Output is resampled
to the engine's 24 kHz so the rest of the pipeline is unchanged.
"""
from __future__ import annotations

import json
import re
from math import gcd
from pathlib import Path
from typing import Iterator

import numpy as np

OUT_RATE = 24000
PACKS = {
    "melo": ("mlx-community/MeloTTS-English-MLX", 44100),
    "soprano": ("mlx-community/Soprano-1.1-80M-bf16", 32000),
    "clone": ("mlx-community/MOSS-TTS-Nano-100M", 48000),
}
MELO_SPEAKERS = ("EN-US", "EN-BR", "EN_INDIA", "EN-AU")
# The talk-speed setting works by changing the speaking rate where the engine supports it.
SPEED_OK = {"melo"}


def pack_of(voice: str) -> str | None:
    p = (voice or "").split(":", 1)[0]
    return p if p in PACKS else None


def _resample(a: np.ndarray, sr: int) -> np.ndarray:
    if sr == OUT_RATE or a.size == 0:
        return a.astype(np.float32)
    from scipy.signal import resample_poly
    g = gcd(int(sr), OUT_RATE)
    return resample_poly(a, OUT_RATE // g, int(sr) // g).astype(np.float32)


class PackVoices:
    def __init__(self, support_dir: Path, emit=print):
        self.dir = support_dir / "voices"
        self.emit = emit
        self.models: dict[str, object] = {}

    # ---- which voices exist ----
    def clone_names(self) -> list[str]:
        out = []
        for j in sorted(self.dir.glob("*.json")) if self.dir.exists() else []:
            try:
                meta = json.loads(j.read_text())
            except ValueError:
                continue
            if meta.get("consent") and j.with_suffix(".wav").exists():
                out.append(j.stem)
        return out

    def valid(self, voice: str) -> bool:
        p = pack_of(voice)
        if p is None:
            return False
        arg = voice.split(":", 1)[1] if ":" in voice else ""
        if p == "melo":
            return arg in MELO_SPEAKERS
        if p == "soprano":
            return True
        return bool(re.fullmatch(r"[\w .-]{1,40}", arg)) and arg in self.clone_names()

    # ---- loading (GPU thread) ----
    def ensure(self, voice: str) -> None:
        p = pack_of(voice)
        if p is None or p in self.models:
            return
        import gc
        import time
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        for other in list(self.models):   # one pack at a time
            self.models.pop(other, None)
        gc.collect()
        mx.clear_cache()
        t = time.time()
        self.models[p] = load_model(PACKS[p][0])
        self.emit("MEMORY", f"voice pack {p} loaded in {time.time() - t:.1f}s, active={mx.get_active_memory() / 1e9:.2f}GB")

    def unload(self) -> None:
        import gc
        import mlx.core as mx
        self.models.clear()
        gc.collect()
        mx.clear_cache()

    # ---- speech ----
    def generate(self, voice: str, text: str, speed: float = 1.0) -> Iterator[np.ndarray]:
        """Float32 audio at 24 kHz for one sentence."""
        self.ensure(voice)
        p = pack_of(voice)
        m = self.models[p]
        arg = voice.split(":", 1)[1] if ":" in voice else ""
        if p == "melo":
            it = m.generate(text, voice=arg, speed=speed)
        elif p == "soprano":
            it = m.generate(text)
        else:
            it = m.generate(text, ref_audio=str(self.dir / f"{arg}.wav"))
        for r in it:
            sr = int(getattr(r, "sample_rate", 0) or PACKS[p][1])
            yield _resample(np.array(r.audio, dtype=np.float32).reshape(-1), sr)
