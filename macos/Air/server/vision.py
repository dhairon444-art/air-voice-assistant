"""Aria's eyes: Qwen3.5-9B (vision-language, 4-bit) loaded only when the user asks Aria to look at
the screen or an image, and unloaded again after a short idle time so RAM stays low.

The image comes from the Air app (ScreenCaptureKit capture, clipboard, or a file). It never leaves
the Mac; the app deletes the temporary file after use unless the user asked to save it.
"""

from __future__ import annotations

import threading
import time

VISION_MODEL = "mlx-community/Qwen3.5-9B-4bit"
IDLE_UNLOAD_S = 90.0
SPOKEN_RULES = (
    "Answer for speech: two to five short sentences, plain words, no markdown, no lists, no emojis. "
    "Say only what you can actually see; if something is too small or unclear, say so. "
    "If text is visible, you may use the OCR text below to read it exactly."
)


class Vision:
    def __init__(self, emit, gpu_jobs):
        self.emit = emit
        self.gpu_jobs = gpu_jobs  # unload must also happen on the GPU thread
        self.model = None
        self.proc = None
        self.last_used = 0.0
        self.lock = threading.Lock()
        threading.Thread(target=self._idle_loop, name="air-vision-idle", daemon=True).start()

    # Runs on the GPU thread.
    def _ensure_loaded(self) -> float:
        if self.model is not None:
            return 0.0
        import mlx.core as mx
        from mlx_vlm import load

        t0 = time.time()
        self.model, self.proc = load(VISION_MODEL)
        mx.eval(self.model.parameters())
        dt = time.time() - t0
        self.emit("MEMORY", f"vision model loaded in {dt:.1f}s, active={mx.get_active_memory() / 1e9:.2f}GB")
        return dt

    def unload(self) -> None:
        if self.model is None:
            return
        import gc

        import mlx.core as mx

        self.model = None
        self.proc = None
        gc.collect()
        mx.clear_cache()
        self.emit("MEMORY", f"vision model unloaded, active={mx.get_active_memory() / 1e9:.2f}GB")

    def _idle_loop(self) -> None:
        while True:
            time.sleep(10)
            if self.model is not None and time.time() - self.last_used > IDLE_UNLOAD_S:
                done = threading.Event()

                def job():
                    if self.model is not None and time.time() - self.last_used > IDLE_UNLOAD_S:
                        self.unload()
                    done.set()

                self.gpu_jobs.put(job)
                done.wait(30)

    # Runs on the GPU thread (called from a tool).
    def describe(self, image_path: str, question: str, context: str = "", ocr: str = "") -> dict:
        import mlx.core as mx
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        load_s = self._ensure_loaded()
        prompt = f"{question.strip() or 'Describe what you see.'}\n\n{SPOKEN_RULES}"
        if context:
            prompt += f"\n\nContext: {context}"
        if ocr:
            prompt += f"\n\nOCR text from the image (may be partial):\n{ocr[:1800]}"
        p = apply_chat_template(self.proc, self.model.config, prompt, num_images=1, enable_thinking=False)
        t0 = time.time()
        r = generate(self.model, self.proc, p, image=[image_path], max_tokens=180, temperature=0.3, verbose=False)
        text = (r.text if hasattr(r, "text") else str(r)).strip()
        self.last_used = time.time()
        return {"ok": True, "summary": text, "seconds": round(time.time() - t0, 1), "load_s": round(load_s, 1),
                "peak_gb": round(mx.get_peak_memory() / 1e9, 2)}
