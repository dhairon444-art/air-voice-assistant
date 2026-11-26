"""Turn detection for Air's microphone, in plain numpy (no MLX: MLX work on a second thread stalls
the GPU thread's TTS).

Three modes (Settings > Voice > Background noise handling):
  standard    band-limited energy vs an adaptive noise floor (Air's original detector)
  music       music-tolerant: speech must also stand out from the music bed in the speech band,
              look like speech (energy in the voice band, syllable-rate dips), and last longer
              before it can interrupt Aria
  headphones  nothing plays into the mic, so the detector can be quick and sensitive

`sensitivity` (0..1, the Interrupt sensitivity slider) trades missed interruptions for false ones.
"""
from __future__ import annotations

from collections import deque

import numpy as np

RATE = 24000
FRAME = 480            # 20 ms
MODES = ("standard", "music", "headphones")

_win = np.hanning(FRAME).astype(np.float32)
_freqs = np.fft.rfftfreq(512, 1 / RATE)
_VOICE = (_freqs >= 200) & (_freqs <= 4000)
_ALL = _freqs >= 80


class Silero:
    """Silero VAD v5 (2 MB ONNX, CPU): the probability that the last 32 ms contain speech.
    Optional: without onnxruntime or the model file, music mode falls back to the numpy features."""
    def __init__(self, path: str):
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.inter_op_num_threads = so.intra_op_num_threads = 1
        self.sess = ort.InferenceSession(path, sess_options=so, providers=["CPUExecutionProvider"])
        self.state = np.zeros((2, 1, 128), np.float32)
        self.ctx = np.zeros(64, np.float32)
        self.buf = np.zeros(0, np.float32)
        self.sr = np.array(16000, np.int64)
        self.p = 0.0

    def feed(self, x24: np.ndarray) -> float:
        from scipy.signal import resample_poly
        self.buf = np.concatenate((self.buf, x24))
        while self.buf.shape[0] >= 768:                    # 32 ms at 24 kHz -> 512 samples at 16 kHz
            chunk = resample_poly(self.buf[:768], 2, 3).astype(np.float32)
            self.buf = self.buf[768:]
            inp = np.concatenate((self.ctx, chunk))[None, :]
            out, self.state = self.sess.run(None, {"input": inp, "state": self.state, "sr": self.sr})
            self.ctx = chunk[-64:]
            self.p = float(out[0][0])
        return self.p


_silero_path = None


def use_silero(path: str | None) -> bool:
    """Point music mode at the Silero model (call once at start). True when it loads."""
    global _silero_path
    try:
        Silero(path)
        _silero_path = path
        return True
    except Exception:
        _silero_path = None
        return False


class TurnDetector:
    def __init__(self, mode: str = "music", sensitivity: float = 0.5,
                 margin_db: float = 14.0, floor_db: float = -48.0):
        self.mode = mode if mode in MODES else "music"
        self.sensitivity = float(min(1.0, max(0.0, sensitivity)))
        self.margin_db = margin_db
        self.floor_db = floor_db
        self.noise_db = -60.0
        self.prev = 0.0
        # music mode state
        self.bed = deque(maxlen=150)          # 3 s of voice-band levels from frames that weren't speech
        self.env = deque(maxlen=25)           # 500 ms of voice-band levels (for syllable dips)
        self.music_frames = 0                 # recent frames with a strong non-speech bed
        self.rejected = 0                     # loud-but-not-speech frames (shown as "music detected")
        # tuned on 6 music clips x 8 utterances (eval_vad.py)
        self.clear_hi, self.clear_span, self.ratio_min, self.dip_db, self.bed_pct = 9.0, 6.0, 0.30, 8.0, 60
        self.silero = Silero(_silero_path) if (_silero_path and self.mode == "music") else None
        self.p_hi, self.p_span, self.s_clear, self.s_dips = 0.75, 0.3, 0.0, 0.0
        self.prob = 0.0
        # quiet rooms (no music detected): Silero's own threshold and a floor that follows the room
        self.q_p, self.q_margin, self.q_floor = 0.5, 8.0, -60.0
        self.near = 0                         # frames of likely speech that didn't pass (missed-start log)
        self.near_peak = 0.0
        self.missed: tuple | None = None      # (peak probability, threshold, over music) when a start was missed

    # -- the two things the turn loop asks --
    def onset_ms(self, aria_audible: bool) -> int:
        """How long speech must last before it counts (longer to interrupt Aria over music)."""
        if self.mode == "standard":
            return 200
        if self.mode == "headphones":
            return 160 if aria_audible else 140
        if not self.music_present:
            return int(300 - 100 * self.sensitivity) if aria_audible else 200   # 250 ms to interrupt in a quiet room
        if aria_audible:
            return int(420 - 140 * self.sensitivity)     # 350 ms over music at the default sensitivity
        return int(300 - 80 * self.sensitivity)

    @property
    def music_present(self) -> bool:
        return self.mode == "music" and self.music_frames > 100   # about 2 s of steady background sound

    MUSIC_DB = -55.0   # non-speech sound this loud for ~2 s is music or TV, not room noise (~-60 to -70)

    def _track_music(self, level: float) -> None:
        if level > self.MUSIC_DB:
            self.music_frames = min(self.music_frames + 1, 400)
            self.rejected += 1
        else:
            self.music_frames = max(self.music_frames - 2, 0)

    def is_speech(self, x: np.ndarray) -> bool:
        hp = np.empty_like(x)
        hp[0] = x[0] - self.prev
        hp[1:] = x[1:] - 0.94 * x[:-1]
        self.prev = 0.94 * x[-1]
        level = 10 * np.log10(float(np.mean(hp * hp)) + 1e-10)
        if level < self.noise_db:
            self.noise_db = level
        else:
            self.noise_db += 0.01 * (level - self.noise_db)
        self.noise_db = min(max(self.noise_db, -90.0), -35.0)

        if self.mode == "standard":
            return level > max(self.noise_db + self.margin_db, self.floor_db)
        if self.mode == "headphones":
            margin = self.margin_db - 4 - 4 * self.sensitivity
            return level > max(self.noise_db + margin, self.floor_db - 4)

        # ---- music-tolerant ----
        spec = np.abs(np.fft.rfft(x * _win, 512)) ** 2
        voice = float(spec[_VOICE].sum())
        total = float(spec[_ALL].sum()) + 1e-12
        vdb = 10 * np.log10(voice / 512 + 1e-10)
        ratio = voice / total
        self.env.append(vdb)
        bed = float(np.percentile(self.bed, self.bed_pct)) if len(self.bed) >= 25 else -90.0
        if self.silero is not None:
            # A trained speech model decides; the bed check keeps far-away voices (songs) out.
            self.prob = p = self.silero.feed(x)
            music = self.music_present
            if music:
                # Music in the room: confident speech that stands clear of the music bed.
                thr = self.p_hi - self.p_span * self.sensitivity
                dips = self.s_dips <= 0 or (len(self.env) >= 15 and
                                            (max(self.env) - float(np.percentile(self.env, 20))) > self.s_dips)
                speech = p > thr and level > self.floor_db and vdb > bed + self.s_clear and dips
            else:
                # Quiet room: Silero's normal threshold, and a level floor that follows the room noise.
                thr = self.q_p - 0.2 * (self.sensitivity - 0.5)
                speech = p > thr and level > max(self.noise_db + self.q_margin, self.q_floor)
            # Missed-start log: something speech-like for 300 ms+ that never passed.
            if not speech and p > 0.25 and level > self.noise_db + 6:
                self.near += 1
                self.near_peak = max(self.near_peak, p)
            else:
                if self.near >= 15 and not speech:
                    self.missed = (round(self.near_peak, 2), round(thr, 2), music)
                if speech or self.near:
                    self.near, self.near_peak = 0, 0.0
            if not speech:
                self.bed.append(vdb)
                self._track_music(level)
            return speech
        loud = level > max(self.noise_db + self.margin_db, self.floor_db) or (bed > -60 and level > self.floor_db)
        # Speech close to the mic stands well clear of the music bed in the voice band.
        clear = self.clear_hi - self.clear_span * self.sensitivity
        above_bed = vdb > bed + clear
        voiced = ratio > self.ratio_min
        # Syllables: speech dips between syllables within half a second; sustained music doesn't.
        dips = len(self.env) >= 15 and (max(self.env) - float(np.percentile(self.env, 20))) > self.dip_db
        speech = loud and above_bed and voiced and dips
        if not speech:
            self.bed.append(vdb)
            self._track_music(level)
        return speech
