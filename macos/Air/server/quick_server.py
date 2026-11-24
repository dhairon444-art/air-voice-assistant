"""Air's "Myra" mode server (PersonaPlex-MLX).

Runs PersonaPlex-MLX as a child process of Air.app:

* binds to 127.0.0.1 only, on a free port chosen by the OS
* reads every model file from the local Hugging Face cache (no network)
* streams raw 16-bit PCM over a WebSocket to the app's own web UI
* writes each conversation to the "Air" Obsidian vault
* exits as soon as its parent app goes away (stdin EOF or parent PID change)

Lines starting with AIR_STATUS / AIR_READY / AIR_ERROR on stdout are read by
the Swift app.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import queue
import re
import signal
import socket
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

DEFAULT_PERSONA = (
    "You enjoy having a good conversation. Your name is Myra, and you are a warm, kind and "
    "encouraging friend who is genuinely curious about the person you are talking to. Have a "
    "relaxed, friendly conversation. Give full, thoughtful answers of several sentences, explain "
    "things with examples, share your own view, and then ask a gentle follow-up question. Always "
    "be patient, supportive and positive; never sarcastic, dismissive or rude."
)
VOICES = [
    "NATF0", "NATF1", "NATF2", "NATF3",
    "NATM0", "NATM1", "NATM2", "NATM3",
    "VARF0", "VARF1", "VARF2", "VARF3", "VARF4",
    "VARM0", "VARM1", "VARM2", "VARM3", "VARM4",
]
SAMPLE_RATE = 24000
FRAME_SIZE = 1920
TEXT_PAD_ID = 3  # "nothing to say this frame" token in the text stream


import collections  # noqa: E402

from air_common import (  # noqa: E402  (shared with aria_server.py)
    SessionRecorder,
    emit,
    ensure_vault,
    watch_parent,
    write_index,
)


# ------------------------------------------------------------------ server ---


def resolve_files(hf_repo: str, quantized: int | None):
    import huggingface_hub

    def cached(name: str) -> str:
        return huggingface_hub.hf_hub_download(hf_repo, name, local_files_only=True)

    model_file = None
    if quantized in (4, 8):
        try:
            model_file = cached(f"model.q{quantized}.safetensors")
        except Exception:
            model_file = None
    if model_file is None:
        model_file = cached("model.safetensors")
    return {
        "config": cached("config.json"),
        "tokenizer": cached("tokenizer_spm_32k_3.model"),
        "mimi": cached("tokenizer-e351c8d8-checkpoint125.safetensors"),
        "model": model_file,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True)
    parser.add_argument("--ui-dir", required=True)
    parser.add_argument("--parent-pid", type=int)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("-q", "--quantized", type=int, choices=[0, 4, 8], default=4,
                        help="4 or 8-bit quantisation; 0 keeps full bf16 weights")
    parser.add_argument("--group-size", type=int, default=64)
    parser.add_argument("--hf-repo", default="nvidia/personaplex-7b-v1")
    parser.add_argument("--voice", default="NATF2")
    parser.add_argument("--text-prompt", default=DEFAULT_PERSONA)
    parser.add_argument("--seed", type=int, default=-1, help="-1 = new random seed per conversation")
    parser.add_argument("--text-temp", type=float, default=0.7)
    parser.add_argument("--text-topk", type=int, default=25)
    parser.add_argument("--stt-python", default="", help="python with mlx-audio, for transcribing your side")
    parser.add_argument("--stt-model", default="mlx-community/parakeet-tdt-0.6b-v2")
    parser.add_argument("--lag-soft", type=float, default=1.0, help="s behind: skip quiet input frames")
    parser.add_argument("--lag-hard", type=float, default=3.0, help="s behind: skip any input frames")
    parser.add_argument("--full-depformer", action="store_true",
                        help="also sample the (discarded) user-stream codebooks")
    parser.add_argument("--pad-bias", type=float, default=0.0,
                        help="logit bias on the text padding token; negative = the model talks more")
    parser.add_argument("--audio-temp", type=float, default=0.8)
    parser.add_argument("--audio-topk", type=int, default=250)
    parser.add_argument("--steps", type=int, default=4000)
    args = parser.parse_args()

    watch_parent(args.parent_pid)
    vault = Path(args.vault)
    ensure_vault(vault)

    emit("STATUS", "Checking model files (offline)")
    try:
        files = resolve_files(args.hf_repo, args.quantized)
    except Exception as exc:
        emit("ERROR", f"Model files are missing from the local cache: {exc}")
        sys.exit(2)

    emit("STATUS", "Starting MLX")
    import aiohttp
    from aiohttp import web
    import mlx.core as mx
    import numpy as np
    import rustymimi
    import sentencepiece

    from personaplex_mlx import models, utils
    from personaplex_mlx.persona_utils import (
        get_lm_config,
        get_voice_prompt_dir,
        load_lm_weights,
        resolve_voice_prompt,
        seed_all,
        wrap_with_system_tags,
    )

    voice_dir = get_voice_prompt_dir(None, args.hf_repo)
    lm_config = get_lm_config(files["config"], args.hf_repo)
    seed_all(args.seed)
    text_tokenizer = sentencepiece.SentencePieceProcessor(files["tokenizer"])  # type: ignore
    size_gb = os.path.getsize(files["model"]) / 1e9
    precision = f"{args.quantized}-bit" if args.quantized else "bf16 (full precision)"
    emit("STATUS", f"Loading model weights ({size_gb:.1f} GB) at {precision}")
    t0 = time.time()
    model = models.Lm(lm_config)
    model.set_dtype(mx.bfloat16)
    if ".q" in Path(files["model"]).name:
        load_lm_weights(model, lm_config, files["model"], args.quantized)
    else:
        # Full-precision checkpoint: load, then quantise. Group size 64 runs ~20% faster per
        # step than the CLI default of 32 on an M4, which matters for staying near realtime.
        import mlx.nn as nn
        from personaplex_mlx.persona_utils import is_pytorch_weights

        if is_pytorch_weights(files["model"]):
            model.load_pytorch_weights(files["model"], lm_config, strict=True)
        else:
            model.load_weights(files["model"], strict=True)
        if args.quantized in (4, 8):
            nn.quantize(model, bits=args.quantized, group_size=args.group_size)
    if not args.full_depformer:
        # The depformer also predicts the user's 8 audio codebooks, but those are always
        # replaced by the real microphone tokens. Skipping them saves ~10% per step,
        # which matters on a fanless Mac that throttles under sustained load.
        n_out = lm_config.audio_tokens_per_stream
        model.depformer.slices = model.depformer.slices[:n_out]
    mx.eval(model.parameters())
    mx.clear_cache()
    emit("STATUS", f"Model loaded in {time.time() - t0:.0f}s")

    gen = models.LmGen(
        model=model,
        max_steps=args.steps + 1024,
        text_sampler=utils.Sampler(temp=args.text_temp, top_k=args.text_topk),
        audio_sampler=utils.Sampler(temp=args.audio_temp, top_k=args.audio_topk),
        check=False,
        audio_silence_frame_cnt=int(0.5 * 12.5),
    )
    emit("STATUS", "Warming up")
    gen.reset_streaming()
    warm = gen._encode_sine_frame()
    for _ in range(16):
        tok = gen.step(input_tokens=warm)
        if tok is not None:
            tok[0].item()
        last = gen.last_audio_tokens()
        if last is not None:
            np.array(last)
    gen.reset_streaming()

    emit("MEMORY", f"active={mx.get_active_memory() / 1e9:.2f}GB peak={mx.get_peak_memory() / 1e9:.2f}GB")

    class PadBiasSampler:
        """Shifts the text 'padding' logit (last axis) before sampling."""

        def __init__(self, inner, bias: float):
            self.inner = inner
            vocab = lm_config.text_out_vocab_size
            b = np.zeros(vocab, dtype=np.float32)
            b[TEXT_PAD_ID] = bias
            self.bias = mx.array(b)

        def __call__(self, logits):
            return self.inner(logits + self.bias.astype(logits.dtype))

    lock = asyncio.Lock()
    ui_dir = Path(args.ui_dir)

    def qfloat(request, key: str, default: float, lo: float, hi: float) -> float:
        try:
            return min(hi, max(lo, float(request.query.get(key, default))))
        except ValueError:
            return default

    async def handle_chat(request: web.Request):
        ws = web.WebSocketResponse(max_msg_size=0)
        await ws.prepare(request)
        voice = request.query.get("voice") or args.voice
        if voice not in VOICES:
            voice = args.voice
        persona = (request.query.get("persona") or args.text_prompt).strip() or DEFAULT_PERSONA
        text_temp = qfloat(request, "text_temp", args.text_temp, 0.0, 1.5)
        text_topk = int(qfloat(request, "text_topk", args.text_topk, 1, 500))
        audio_temp = qfloat(request, "audio_temp", args.audio_temp, 0.0, 1.5)
        audio_topk = int(qfloat(request, "audio_topk", args.audio_topk, 1, 2048))
        pad_bias = qfloat(request, "pad_bias", args.pad_bias, -3.0, 1.0)
        seed = args.seed if args.seed >= 0 else int.from_bytes(os.urandom(4), "little")
        if lock.locked():
            await ws.send_bytes(b"\x03" + "Another conversation is already running.".encode())
            await ws.close()
            return ws

        voice_path = resolve_voice_prompt(None, voice, voice_dir)
        audio_tokenizer = rustymimi.StreamTokenizer(files["mimi"], num_codebooks=8)  # type: ignore
        text_q: queue.Queue[str] = queue.Queue()
        state = {"close": False, "steps": 0, "step_time": 0.0, "error": None,
                 "in_frames": 0, "done_frames": 0, "skipped": 0, "lag": 0.0, "lag_max": 0.0}
        frame_rms: collections.deque = collections.deque()
        mic_chunks: list[bytes] = []  # your side, 24 kHz int16, transcribed after the session
        loop = asyncio.get_running_loop()
        prepared = asyncio.Event()
        recorder: SessionRecorder | None = None

        def model_worker():
            """All MLX work for a session runs on this one thread, so the event loop stays
            free to feed the Mimi encoder and send audio while the GPU computes."""
            try:
                seed_all(seed)
                gen.text_sampler = utils.Sampler(temp=text_temp, top_k=text_topk)
                if pad_bias:
                    gen.text_sampler = PadBiasSampler(gen.text_sampler, pad_bias)
                gen.audio_sampler = utils.Sampler(temp=audio_temp, top_k=audio_topk)
                gen.reset_streaming()
                gen.load_voice_prompt_embeddings(voice_path)
                gen.text_prompt_tokens = text_tokenizer.encode(wrap_with_system_tags(persona))  # type: ignore
                gen.step_system_prompts()
                mx.eval(gen.cache)
            except Exception as exc:  # surface to the client
                state["error"] = str(exc)
                state["close"] = True
            finally:
                loop.call_soon_threadsafe(prepared.set)
            while not state["close"]:
                tokens = audio_tokenizer.get_encoded()
                if tokens is None:
                    time.sleep(0.002)
                    continue
                # Catch-up: when the model falls behind the microphone (a fanless Mac slows down
                # as it heats up), skip quiet input frames, and past the hard limit any frames,
                # so the delay cannot keep growing.
                state["done_frames"] += 1
                rms = frame_rms.popleft() if frame_rms else 0.0
                lag = max(0.0, (state["in_frames"] - state["done_frames"]) * FRAME_SIZE / SAMPLE_RATE)
                state["lag"] = lag
                state["lag_max"] = max(state["lag_max"], lag)
                if lag > args.lag_hard or (lag > args.lag_soft and rms < 0.01):
                    state["skipped"] += 1
                    continue
                t_step = time.perf_counter()
                model_input = mx.array(tokens).transpose(1, 0)[:, : gen.user_codebooks][:, :, None]
                text_token = gen.step(input_tokens=model_input)
                if text_token is not None:
                    value = int(text_token[0].item())
                    if value not in (0, 3):
                        piece = text_tokenizer.id_to_piece(value).replace("▁", " ")  # type: ignore
                        if not (piece.startswith("<") and piece.endswith(">")):
                            text_q.put(piece)
                audio_tokens = gen.last_audio_tokens()
                if audio_tokens is not None:
                    audio_tokenizer.decode(np.array(audio_tokens).astype(np.uint32))
                state["steps"] += 1
                dt = time.perf_counter() - t_step
                state["step_time"] += dt
                state["win"] = state.get("win", 0.0) + dt
                if state["steps"] % 125 == 0:  # every ~10 s of audio
                    emit("PERF", f"step {state['steps']}: {8 * state['win']:.1f} ms/step over last 125, "
                                 f"behind by {state['lag']:.1f}s, skipped {state['skipped']} frames")
                    state["win"] = 0.0

        async def recv_loop():
            buf = np.zeros(0, dtype=np.float32)
            try:
                async for message in ws:
                    if message.type != aiohttp.WSMsgType.BINARY:
                        if message.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE):
                            break
                        continue
                    data = message.data
                    if not data or data[0] != 1:
                        continue
                    mic_chunks.append(bytes(data[1:]))
                    pcm = np.frombuffer(data[1:], dtype="<i2").astype(np.float32) / 32768.0
                    buf = np.concatenate((buf, pcm))
                    while buf.shape[-1] >= FRAME_SIZE:
                        frame = buf[:FRAME_SIZE]
                        level = float(np.sqrt(np.mean(frame * frame)))
                        frame_rms.append(level)
                        if level > 0.02:  # you are talking: Myra's next words start a new line
                            state["you_t"] = time.monotonic()
                        state["in_frames"] += 1
                        audio_tokenizer.encode(frame)  # non-blocking, runs on mimi's thread
                        buf = buf[FRAME_SIZE:]
            finally:
                state["close"] = True

        async def send_loop():
            while not state["close"]:
                await asyncio.sleep(0.002)
                if ws.closed:
                    state["close"] = True
                    return
                try:
                    while True:
                        decoded = audio_tokenizer.get_decoded()
                        if decoded is None:
                            break
                        pcm16 = (np.clip(decoded, -1.0, 1.0) * 32767.0).astype("<i2")
                        await ws.send_bytes(b"\x01" + pcm16.tobytes())
                    now = time.monotonic()
                    if now - state.get("lag_sent", 0.0) > 1.0:
                        state["lag_sent"] = now
                        await ws.send_bytes(b"\x08" + f"{state['lag']:.1f}".encode())
                    while not text_q.empty():
                        piece = text_q.get_nowait()
                        if recorder is not None:
                            now_t = time.monotonic()
                            new_line = (state.get("you_t", 0.0) > state.get("piece_t", 0.0)
                                        and now_t - state.get("line_t", 0.0) > 4.0)
                            if new_line:
                                state["line_t"] = now_t
                            state["piece_t"] = now_t
                            recorder.add_text(piece, new_line=new_line)
                        await ws.send_bytes(b"\x02" + piece.encode("utf-8"))
                except (aiohttp.ClientConnectionResetError, ConnectionResetError):
                    state["close"] = True
                    return

        async def autosave_loop():
            while not state["close"]:
                await asyncio.sleep(10)
                if recorder is not None and recorder.has_text() and not recorder.finished:
                    try:
                        recorder.save(final=False)
                    except OSError as exc:
                        emit("ERROR", f"autosave failed: {exc}")

        async with lock:
            emit("STATUS", f"session start voice={voice} text_temp={text_temp} text_topk={text_topk} "
                           f"audio_temp={audio_temp} audio_topk={audio_topk} pad_bias={pad_bias}")
            worker = threading.Thread(target=model_worker, name="air-model", daemon=True)
            worker.start()
            await prepared.wait()
            if state["error"]:
                emit("STATUS", f"session failed: {state['error']}")
                await ws.send_bytes(b"\x03" + f"Could not start: {state['error']}".encode())
                await ws.close()
                await asyncio.to_thread(worker.join)
                return ws
            recorder = SessionRecorder(vault, voice, persona, mode="Myra", model_id=args.hf_repo,
                                       assistant="Myra", user_side=False)
            await ws.send_bytes(b"\x00")
            try:
                await asyncio.gather(recv_loop(), send_loop(), autosave_loop())
            finally:
                state["close"] = True
                await asyncio.to_thread(worker.join, 5)
                path = recorder.finish()
                if path is not None and args.stt_python and mic_chunks:
                    await transcribe_user_side(recorder, b"".join(mic_chunks))
                if path is not None:
                    emit("SESSION_SAVED", str(path))
                if state["steps"]:
                    ms = 1000 * state["step_time"] / state["steps"]
                    emit("STATUS", f"session end: {state['steps']} steps, {ms:.1f} ms/step "
                                   f"({80.0 / ms:.2f}x realtime), behind by {state['lag']:.1f}s at end "
                                   f"(max {state['lag_max']:.1f}s, skipped {state['skipped']} frames), "
                                   f"peak {mx.get_peak_memory() / 1e9:.2f}GB")
                else:
                    emit("STATUS", "session end")
        return ws

    async def transcribe_user_side(recorder, pcm24: bytes) -> None:
        """After the session: transcribe your microphone with Parakeet (Aria's venv, a short-lived
        helper process) and interleave 'You' lines by time. The audio is deleted afterwards."""
        import tempfile
        import wave

        if len(pcm24) < SAMPLE_RATE * 2:  # under 1 s
            return
        emit("STATUS", "transcribing your side of the conversation")
        cache = Path.home() / "Library/Caches/Air"
        cache.mkdir(parents=True, exist_ok=True)
        fd, wav_path = tempfile.mkstemp(suffix=".wav", dir=cache)
        os.close(fd)
        try:
            with wave.open(wav_path, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(SAMPLE_RATE)
                w.writeframes(pcm24)
            env = dict(os.environ, HF_HUB_OFFLINE="1", PYTHONNOUSERSITE="1")
            env.pop("PYTHONPATH", None)
            t0 = time.time()
            proc = await asyncio.create_subprocess_exec(
                args.stt_python, "-s", str(Path(__file__).with_name("transcribe.py")),
                wav_path, args.stt_model, env=env,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            out, _ = await proc.communicate()
            sentences = json.loads(out.decode().strip().splitlines()[-1]) if out.strip() else []
            for seg in sentences:
                recorder.add_segment(seg["start"], "You", seg["text"])
            recorder.user_side = True
            recorder.save(final=True)
            write_index(recorder.vault)
            emit("STATUS", f"transcribed your side: {len(sentences)} sentences in {time.time() - t0:.1f}s")
        except Exception as exc:
            emit("ERROR", f"could not transcribe your side: {exc!r}")
        finally:
            Path(wav_path).unlink(missing_ok=True)

    async def handle_root(_):
        resp = web.FileResponse(ui_dir / "index.html")
        resp.headers["Cache-Control"] = "no-store"
        return resp

    async def handle_status(_):
        return web.json_response({"ready": True, "busy": lock.locked(), "voices": VOICES})

    app = web.Application()
    app.router.add_get("/", handle_root)
    app.router.add_get("/api/chat", handle_chat)
    app.router.add_get("/api/status", handle_status)
    app.router.add_static("/static/", path=str(ui_dir), name="static")

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", args.port))
    port = sock.getsockname()[1]

    async def run():
        runner = web.AppRunner(app, handle_signals=False)
        await runner.setup()
        site = web.SockSite(runner, sock)
        await site.start()
        emit("READY", str(port))
        await asyncio.Event().wait()

    asyncio.run(run())


if __name__ == "__main__":
    main()
