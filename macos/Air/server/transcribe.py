"""Transcribe a WAV with Parakeet (run with the Aria venv). Prints JSON:
[{"start": s, "end": s, "text": "..."}, ...]   (offline: HF_HUB_OFFLINE=1)"""
import json
import sys

import numpy as np


def main() -> None:
    import wave

    import mlx.core as mx
    from mlx_audio.stt.utils import load as load_stt
    from scipy.signal import resample_poly

    path, model_id = sys.argv[1], sys.argv[2]
    w = wave.open(path)
    sr = w.getframerate()
    audio = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
    if sr != 16000:
        audio = resample_poly(audio, 16000, sr).astype(np.float32)
    stt = load_stt(model_id)
    secs = len(audio) / 16000
    if secs <= 15 * 60:
        result = stt.generate(mx.array(audio))
    else:  # very long sessions: chunk to bound memory
        result = stt.generate(mx.array(audio), chunk_duration=120.0, overlap_duration=5.0)
    out = [{"start": float(s.start), "end": float(s.end), "text": s.text.strip()}
           for s in getattr(result, "sentences", []) if s.text.strip()]
    if not out and result.text.strip():
        out = [{"start": 0.0, "end": len(audio) / 16000, "text": result.text.strip()}]
    print(json.dumps(out))


if __name__ == "__main__":
    main()
