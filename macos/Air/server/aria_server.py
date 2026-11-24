"""Air's "Aria" mode server: a fast local voice pipeline.

    microphone -> energy VAD (turn taking) -> Parakeet STT -> local LLM (streamed)
               -> sentence chunks -> Kokoro TTS -> speaker

* binds to 127.0.0.1 only, all models from the local Hugging Face cache
* the reply starts playing after the first sentence while the rest is generated
* if you start talking while Aria speaks, playback stops and Aria listens
* both sides of the conversation are saved to the Air Obsidian vault

WebSocket protocol (same framing as the Myra server, plus a few kinds):
  client -> server  0x01 + int16 PCM @ 24 kHz      microphone
                    text JSON {"type":"end_turn"}  manual "Done talking"
  server -> client  0x00                           ready
                    0x01 + int16 PCM @ 24 kHz      Aria's voice
                    0x02 + utf-8                   Aria's text (per spoken sentence)
                    0x03 + utf-8                   error
                    0x05 + utf-8                   your transcribed turn
                    0x06                           stop playback now (barge-in)
                    0x07 + utf-8                   state: listening|hearing|thinking|speaking
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import queue
import re
import socket
import sys
import threading
import time
from pathlib import Path

from air_common import SessionRecorder, emit, ensure_vault, watch_parent

DEFAULT_PERSONA = (
    "You enjoy having a good conversation. Your name is Aria, and you are a warm, kind and "
    "encouraging friend who is genuinely curious about the person you are talking to. Have a "
    "relaxed, friendly conversation. Give full, thoughtful answers of several sentences, explain "
    "things with examples, share your own view, and then ask a gentle follow-up question. Always "
    "be patient, supportive and positive; never sarcastic, dismissive or rude."
)
# Always appended: the reply is spoken, not read.
SPOKEN_STYLE = (
    "You are talking out loud with the user through a voice interface. Reply in natural spoken "
    "English, the way a thoughtful person talks: complete sentences, no markdown, no bullet "
    "points or numbered lists, no headings, no emojis, no URLs. Spell out symbols and abbreviations "
    "the way you would say them. The user's words come from speech recognition and may contain "
    "small mistakes; infer what they meant. Keep each reply to about three to six sentences "
    "so the conversation stays a back-and-forth; go longer only when the user asks for detail."
)
FEMALE_VOICES = ["af_heart", "af_bella", "af_nicole", "af_aoede", "af_kore", "af_sarah",
                 "af_nova", "af_sky", "af_jessica", "af_river", "af_alloy", "bf_emma",
                 "bf_isabella", "bf_alice", "bf_lily"]

MIC_RATE = 24000
STT_RATE = 16000
TTS_RATE = 24000


def to_ascii_quotes(s: str) -> str:
    return (s.replace("’", "'").replace("‘", "'").replace("“", '"')
             .replace("”", '"').replace("—", ", ").replace("–", ", "))


def clean_for_speech(s: str) -> str:
    s = re.sub(r"<think>.*?</think>", "", s, flags=re.S)
    s = re.sub(r"[*_#`>|]+", "", s)
    s = re.sub(r"^\s*[-•]\s+", "", s, flags=re.M)
    s = re.sub(r"\s+", " ", s)
    return to_ascii_quotes(s).strip()


_SENT_END = re.compile(r"([.!?]+[\"')\]]?)(\s+|$)")


def pop_sentence(buf: str, first: bool) -> tuple[str | None, str]:
    """Return (chunk, rest) once `buf` holds a complete sentence worth speaking."""
    min_len = 4 if first else 40
    if first:
        # Start speaking as early as possible: a clause ending in a comma is enough.
        m = re.search(r"[,;:]\s", buf[8:])
        if m and not _SENT_END.search(buf[: 8 + m.end()]):
            cut = 8 + m.end()
            return buf[:cut].strip(), buf[cut:]
    for m in _SENT_END.finditer(buf):
        if m.end() >= min_len and m.group(2):
            return buf[: m.end()].strip(), buf[m.end():]
    # Very long run-on with no full stop yet: break at a comma so speech can start.
    if len(buf) > (90 if first else 160):
        cut = buf.rfind(", ", 0, len(buf) - 1)
        if cut > 30:
            return buf[: cut + 1].strip(), buf[cut + 2:]
    return None, buf


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--vault", required=True)
    p.add_argument("--ui-dir", required=True)
    p.add_argument("--parent-pid", type=int)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--llm", default="mlx-community/Qwen3-4B-Instruct-2507-4bit")
    p.add_argument("--stt", default="mlx-community/parakeet-tdt-0.6b-v2")
    p.add_argument("--tts", default="mlx-community/Kokoro-82M-bf16")
    p.add_argument("--voice", default="af_heart")
    p.add_argument("--text-prompt", default=DEFAULT_PERSONA)
    p.add_argument("--max-tokens", type=int, default=450)
    p.add_argument("--temp", type=float, default=0.7)
    p.add_argument("--silence-ms", type=int, default=600, help="pause that ends your turn")
    p.add_argument("--vad-margin-db", type=float, default=14.0, help="speech must be this far above the noise floor")
    p.add_argument("--vad-floor-db", type=float, default=-48.0, help="and above this absolute level")
    args = p.parse_args()

    watch_parent(args.parent_pid)
    vault = Path(args.vault)
    ensure_vault(vault)

    emit("STATUS", "Starting MLX")
    import aiohttp
    from aiohttp import web
    import mlx.core as mx
    import numpy as np
    from scipy.signal import resample_poly

    def cached(repo: str) -> str:
        from huggingface_hub import snapshot_download
        return snapshot_download(repo, local_files_only=True)

    try:
        for k in ("stt", "tts", "llm"):  # presence check only; loaders resolve repo ids offline
            cached(getattr(args, k))
    except Exception as exc:
        emit("ERROR", f"Aria's models are missing from the local cache: {exc}")
        sys.exit(2)

    t0 = time.time()
    emit("STATUS", "Loading speech recognition (Parakeet)")
    from mlx_audio.stt.utils import load as load_stt
    stt = load_stt(args.stt)
    emit("STATUS", "Loading voice (Kokoro)")
    from mlx_audio.tts.utils import load_model as load_tts
    tts = load_tts(args.tts)
    emit("STATUS", f"Loading language model ({args.llm.split('/')[-1]})")
    from mlx_lm import load as load_lm, stream_generate
    from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache
    from mlx_lm.sample_utils import make_sampler
    lm, tokenizer = load_lm(args.llm)

    emit("STATUS", f"Warming up (loaded in {time.time() - t0:.0f}s)")
    tw = time.time()
    rng = np.random.default_rng(0)
    for secs in (1.0, 2.5, 4.0):  # realistic shapes so real turns don't pay kernel compile
        stt.generate(mx.array((rng.standard_normal(int(STT_RATE * secs)) * 0.05).astype(np.float32)))
    emit("STATUS", f"Warm-up: speech recognition {time.time() - tw:.1f}s")
    tw = time.time()
    for _ in tts.generate("Hello there.", voice=args.voice):
        pass
    emit("STATUS", f"Warm-up: voice {time.time() - tw:.1f}s")
    tw = time.time()
    for _ in stream_generate(lm, tokenizer, "Hello", max_tokens=2):
        pass
    emit("STATUS", f"Warm-up: language model {time.time() - tw:.1f}s")
    mx.clear_cache()
    emit("STATUS", f"Models loaded in {time.time() - t0:.0f}s")
    emit("MEMORY", f"active={mx.get_active_memory() / 1e9:.2f}GB peak={mx.get_peak_memory() / 1e9:.2f}GB")

    model_ids = f"{args.llm} + {args.stt} + {args.tts} ({args.voice})"
    lock = asyncio.Lock()
    ui_dir = Path(args.ui_dir)
    # One thread owns all GPU (MLX) work; VAD runs on the CPU stream next to it.
    gpu_jobs: queue.Queue = queue.Queue()

    def gpu_worker():
        # MLX streams are per thread: this thread gets its own GPU stream.
        with mx.stream(mx.new_stream(mx.gpu)):
            while True:
                fn = gpu_jobs.get()
                try:
                    fn()
                except Exception as exc:  # keep the worker alive
                    emit("ERROR", f"model job failed: {exc!r}")

    threading.Thread(target=gpu_worker, name="air-gpu", daemon=True).start()

    async def handle_chat(request: web.Request):
        ws = web.WebSocketResponse(max_msg_size=0)
        await ws.prepare(request)
        if lock.locked():
            await ws.send_bytes(b"\x03" + b"Another conversation is already running.")
            await ws.close()
            return ws
        async with lock:
            await run_session(request, ws)
        return ws

    async def run_session(request, ws):
        loop = asyncio.get_running_loop()
        voice = request.query.get("voice") or args.voice
        if voice not in FEMALE_VOICES:
            voice = args.voice
        persona = (request.query.get("persona") or args.text_prompt).strip() or DEFAULT_PERSONA
        system = persona + "\n\n" + SPOKEN_STYLE
        recorder = SessionRecorder(vault, voice, persona, mode="Aria", model_id=model_ids,
                                   assistant="Aria", user_side=True)
        messages: list[dict] = [{"role": "system", "content": system}]
        st = {
            "gen": 0,                 # bumped to cancel the reply being generated
            "play_until": 0.0,        # monotonic time when queued audio finishes playing
            "busy": False,            # a reply is being generated
            "closed": False,
            "cache": make_prompt_cache(lm),
            "cache_tokens": [],
            "latencies": [],
        }
        out_q: asyncio.Queue = asyncio.Queue()

        def send(kind: int, payload: bytes = b"") -> None:
            loop.call_soon_threadsafe(out_q.put_nowait, bytes([kind]) + payload)

        def set_state(s: str) -> None:
            send(7, s.encode())

        # ---------------- VAD (CPU stream, its own thread) ----------------
        mic_q: queue.Queue = queue.Queue()
        utter: list = []          # 16 kHz float chunks of the current user turn
        pre: list = []            # rolling 300 ms pre-roll
        turn = {"speaking": False, "speech_ms": 0.0, "silence_ms": 0.0, "end_t": 0.0}

        def assistant_audible() -> bool:
            return st["busy"] or time.monotonic() < st["play_until"]

        def barge_in():
            st["gen"] += 1
            st["play_until"] = 0.0
            send(6)

        def end_turn(manual: bool = False):
            audio = np.concatenate(utter) if utter else np.zeros(0, np.float32)
            utter.clear()
            turn["speaking"] = False
            turn["speech_ms"] = 0.0
            if audio.shape[0] < STT_RATE * 0.25:
                set_state("listening")
                return
            # end of speech = now minus the trailing silence we waited for
            t_end = time.monotonic() - (0 if manual else args.silence_ms / 1000.0)
            gen_id = st["gen"] + 1
            st["gen"] = gen_id
            st["busy"] = True
            set_state("thinking")
            gpu_jobs.put(lambda: reply(audio, t_end, gen_id))

        def vad_loop():
            """Turn detection in plain numpy (no MLX here: MLX work on a second thread stalls
            the GPU thread's TTS). 20 ms frames, band-limited energy vs an adaptive noise floor."""
            frame = 320  # 20 ms at 16 kHz
            buf = np.zeros(0, np.float32)
            noise_db = -60.0
            prev = 0.0
            while not st["closed"]:
                try:
                    item = mic_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                if isinstance(item, str):  # "END": manual end of turn
                    if utter or turn["speaking"]:
                        end_turn(manual=True)
                    continue
                buf = np.concatenate((buf, item))
                while buf.shape[0] >= frame:
                    x = buf[:frame]
                    buf = buf[frame:]
                    # first-order high-pass (~150 Hz) to ignore rumble and handling noise
                    hp = np.empty_like(x)
                    hp[0] = x[0] - prev
                    hp[1:] = x[1:] - 0.94 * x[:-1]
                    prev = 0.94 * x[-1]
                    level = 10 * np.log10(float(np.mean(hp * hp)) + 1e-10)
                    if level < noise_db:
                        noise_db = level
                    else:
                        noise_db += 0.01 * (level - noise_db)  # rise slowly
                    noise_db = min(max(noise_db, -90.0), -35.0)
                    speech = level > max(noise_db + args.vad_margin_db, args.vad_floor_db)
                    if turn["speaking"] or speech:
                        utter.append(x)
                    else:
                        pre.append(x)
                        if len(pre) > 15:  # 300 ms pre-roll
                            pre.pop(0)
                    if speech:
                        turn["speech_ms"] += 20
                        turn["silence_ms"] = 0
                        if not turn["speaking"] and turn["speech_ms"] >= 200:
                            turn["speaking"] = True
                            utter[:0] = pre[:]
                            pre.clear()
                            if assistant_audible():
                                barge_in()
                            set_state("hearing")
                    elif turn["speaking"]:
                        turn["silence_ms"] += 20
                        if turn["silence_ms"] >= args.silence_ms:
                            end_turn()
                    else:
                        turn["speech_ms"] = max(0.0, turn["speech_ms"] - 20)
                        if turn["speech_ms"] == 0:
                            utter.clear()

        threading.Thread(target=vad_loop, name="air-vad", daemon=True).start()

        # ---------------- reply: STT -> LLM -> TTS (GPU thread) ----------------
        def reply(audio, t_end: float, gen_id: int):
            def cancelled() -> bool:
                return gen_id != st["gen"] or st["closed"]

            try:
                t_stt = time.monotonic()
                text = stt.generate(mx.array(audio)).text.strip()
                stt_ms = (time.monotonic() - t_stt) * 1000
                if not text or cancelled():
                    set_state("listening")
                    return
                send(5, text.encode())
                spoke_at = t_end - audio.shape[0] / STT_RATE - recorder.start_mono
                recorder.add_segment(spoke_at, "You", text)
                messages.append({"role": "user", "content": text})

                prompt = tokenizer.apply_chat_template(
                    messages, add_generation_prompt=True, tokenize=True, enable_thinking=False)
                prompt = list(prompt)
                # Reuse the KV cache for the shared prefix of the conversation.
                cached = st["cache_tokens"]
                common = 0
                for a, b in zip(cached, prompt):
                    if a != b:
                        break
                    common += 1
                common = min(common, len(prompt) - 1)
                if len(cached) > common:
                    trim_prompt_cache(st["cache"], len(cached) - common)
                feed = prompt[common:]

                sampler = make_sampler(temp=args.temp, top_p=0.9)
                spoken: list[str] = []
                full = ""
                buf = ""
                first_audio = None
                n_tok = 0
                t_llm = time.monotonic()
                marks = {"stt_done": t_stt + stt_ms / 1000}
                perf = {"tts_s": 0.0, "audio_s": 0.0}
                in_think = False

                def speak(chunk: str) -> bool:
                    nonlocal first_audio
                    chunk = clean_for_speech(chunk)
                    if not chunk:
                        return True
                    if "chunk1" not in marks:
                        marks["chunk1"] = time.monotonic()
                    t_tts = time.monotonic()
                    for res in tts.generate(chunk, voice=voice):
                        if cancelled():
                            return False
                        pcm = np.array(res.audio).reshape(-1)
                        pcm16 = (np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes()
                        now = time.monotonic()
                        if first_audio is None:
                            first_audio = now
                            set_state("speaking")
                        st["play_until"] = max(st["play_until"], now) + pcm.shape[0] / TTS_RATE
                        perf["audio_s"] += pcm.shape[0] / TTS_RATE
                        send(1, pcm16)
                    send(2, (chunk + " ").encode())
                    spoken.append(chunk)
                    perf["tts_s"] += time.monotonic() - t_tts
                    return True

                for resp in stream_generate(lm, tokenizer, feed, max_tokens=args.max_tokens,
                                            sampler=sampler, prompt_cache=st["cache"]):
                    n_tok += 1
                    full += resp.text
                    if cancelled():
                        break
                    piece = resp.text
                    if "<think>" in piece:
                        in_think = True
                    if in_think:
                        if "</think>" in piece:
                            in_think = False
                            piece = piece.split("</think>", 1)[1]
                        else:
                            continue
                    buf += piece
                    while True:
                        chunk, buf = pop_sentence(buf, first=not spoken)
                        if chunk is None:
                            break
                        if not speak(chunk):
                            break
                    if cancelled():
                        break
                if not cancelled() and buf.strip():
                    speak(buf)
                llm_s = time.monotonic() - t_llm

                # Track exactly which tokens the KV cache now holds.
                offset = st["cache"][0].offset if hasattr(st["cache"][0], "offset") else None
                gen_tokens = tokenizer.encode(full, add_special_tokens=False) if full else []
                all_tokens = prompt + gen_tokens
                st["cache_tokens"] = all_tokens[:offset] if offset is not None else []
                if offset is None:
                    st["cache"] = make_prompt_cache(lm)

                said = " ".join(spoken).strip()
                interrupted = cancelled() and not st["closed"]
                if said:
                    recorder.add_segment((first_audio or time.monotonic()) - recorder.start_mono, "Aria",
                                         said + (" [interrupted]" if interrupted else ""))
                    # Keep the model's exact words when it finished, so the next prompt's
                    # prefix matches the KV cache and only the new turn is processed.
                    raw = re.sub(r"<think>.*?</think>", "", full, flags=re.S).strip()
                    messages.append({"role": "assistant",
                                     "content": (said + " ...") if interrupted else (raw or said)})
                if first_audio is not None:
                    lat = first_audio - t_end
                    st["latencies"].append(lat)
                    emit("LATENCY", f"end-of-speech to first audio {lat:.2f}s = wait for pause "
                                    f"{t_stt - t_end:.2f} + stt {stt_ms / 1000:.2f} + llm to first clause "
                                    f"{marks.get('chunk1', first_audio) - marks['stt_done']:.2f} + tts "
                                    f"{first_audio - marks.get('chunk1', first_audio):.2f} (stt {stt_ms:.0f} ms, "
                                    f"prompt {len(feed)} new tokens, {n_tok} tokens, llm {n_tok / max(llm_s - perf['tts_s'], 1e-6):.1f} tok/s, "
                                    f"tts {perf['tts_s']:.1f}s for {perf['audio_s']:.1f}s audio, total {llm_s:.1f}s){' interrupted' if interrupted else ''}")
            finally:
                if gen_id == st["gen"]:
                    st["busy"] = False
                    if not st["closed"]:
                        set_state("listening")

        # ---------------- websocket plumbing ----------------
        async def sender():
            while True:
                msg = await out_q.get()
                if msg is None or ws.closed:
                    return
                try:
                    await ws.send_bytes(msg)
                except (aiohttp.ClientConnectionResetError, ConnectionResetError):
                    return

        async def autosave():
            while not st["closed"]:
                await asyncio.sleep(10)
                if recorder.has_text() and not recorder.finished:
                    try:
                        recorder.save(final=False)
                    except OSError as exc:
                        emit("ERROR", f"autosave failed: {exc}")

        def prime():
            """Prefill the system prompt now so the first turn only processes the user's words."""
            sys_tokens = list(tokenizer.apply_chat_template(
                messages, add_generation_prompt=False, tokenize=True, enable_thinking=False))
            for _ in stream_generate(lm, tokenizer, sys_tokens, max_tokens=1, prompt_cache=st["cache"]):
                pass
            off = st["cache"][0].offset
            st["cache_tokens"] = sys_tokens[:off]

        gpu_jobs.put(prime)
        emit("STATUS", f"session start mode=Aria voice={voice}")
        await ws.send_bytes(b"\x00")
        set_state("listening")
        send_task = asyncio.create_task(sender())
        save_task = asyncio.create_task(autosave())
        carry = np.zeros(0, np.float32)
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.BINARY and msg.data and msg.data[0] == 1:
                    pcm = np.frombuffer(msg.data[1:], dtype="<i2").astype(np.float32) / 32768.0
                    carry = np.concatenate((carry, pcm))
                    n = (carry.shape[0] // 3) * 3
                    if n:
                        mic_q.put(resample_poly(carry[:n], 2, 3).astype(np.float32))
                        carry = carry[n:]
                elif msg.type == aiohttp.WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                    except ValueError:
                        continue
                    if data.get("type") == "end_turn":
                        mic_q.put("END")
                    elif data.get("type") == "stop_speaking":
                        barge_in()
                elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE):
                    break
        finally:
            st["closed"] = True
            st["gen"] += 1
            out_q.put_nowait(None)
            save_task.cancel()
            # wait for any in-flight reply to notice the cancel
            done = threading.Event()
            gpu_jobs.put(done.set)
            await asyncio.to_thread(done.wait, 10)
            path = recorder.finish()
            if path is not None:
                emit("SESSION_SAVED", str(path))
            lats = st["latencies"]
            if lats:
                emit("STATUS", f"session end: {len(lats)} replies, latency median "
                               f"{sorted(lats)[len(lats) // 2]:.2f}s, max {max(lats):.2f}s, "
                               f"peak {mx.get_peak_memory() / 1e9:.2f}GB")
            else:
                emit("STATUS", "session end")
            await send_task

    async def handle_root(_):
        resp = web.FileResponse(ui_dir / "index.html")
        resp.headers["Cache-Control"] = "no-store"
        return resp

    async def handle_status(_):
        return web.json_response({"ready": True, "busy": lock.locked(), "mode": "aria",
                                  "voices": FEMALE_VOICES})

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
        await web.SockSite(runner, sock).start()
        emit("READY", str(port))
        await asyncio.Event().wait()

    asyncio.run(run())


if __name__ == "__main__":
    main()
