"""Air's "Aria" mode server: a fast local voice pipeline.

    microphone -> energy VAD (turn taking) -> Parakeet STT -> local LLM (streamed)
               -> sentence chunks -> Kokoro TTS -> speaker

* binds to 127.0.0.1 only, all models from the local Hugging Face cache
* the reply starts playing after the first sentence while the rest is generated
* if you start talking while Aria speaks, playback stops and Aria listens
* both sides of the conversation are saved to the Air Obsidian vault

WebSocket protocol:
  client -> server  0x01 + int16 PCM @ 24 kHz      microphone
                    text JSON {"type":"end_turn"}  manual "Done talking"
  server -> client  0x00                           ready
                    0x01 + int16 PCM @ 24 kHz      Aria's voice
                    0x02 + utf-8                   Aria's text (per spoken sentence)
                    0x03 + utf-8                   error
                    0x05 + utf-8                   your transcribed turn
                    0x06                           stop playback now (barge-in)
                    0x07 + utf-8                   state: listening|hearing|thinking|checking|working|speaking
                    0x09 + JSON                    UI event: tool start/end, confirm card, sources, saved file
  client -> server  text JSON {"type":"confirm","answer":"yes"|"no"}  tapped Confirm / Cancel
                    text JSON {"type":"say","text":"..."}            a typed turn
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

from air_common import SessionRecorder, call_app_tool, emit, ensure_vault, watch_parent, write_index
from memory import (Memory, add_summary_to_note, build_summary_prompt, merge_profile, parse_json_object,
                    transcript_of)
from web_tools import Connectivity, WebSession
from vision import Vision
from aria_tools import (VISION_TOOLS, WEB_TOOLS, NEEDS_CONFIRMATION, ON_HOLD, TOOL_GUIDE, TOOL_NAMES, TOOLS, classify_reply,
                        describe, parse_tool_calls, announces_action, claims_action, NUDGE, HONEST,
                        looks_like_tool_text,
                        ACTION_TOOLS)

def _default_persona() -> str:
    """The Analyst personality from Resources/personas.json (shipped next to server/)."""
    try:
        presets = json.loads((Path(__file__).resolve().parent.parent / "personas.json").read_text())
        return next(p["text"] for p in presets if p["id"] == "analyst")
    except Exception:
        return "You are Aria. Be accurate, direct and never flattering; correct the user plainly when they are wrong."


DEFAULT_PERSONA = _default_persona()
# Always appended: the reply is spoken, not read.
SPOKEN_STYLE = (
    "You are talking out loud with the user through a voice interface. Reply in natural spoken "
    "English, the way a thoughtful person talks: complete sentences, no markdown, no bullet "
    "points or numbered lists, no headings, no emojis, no URLs. Spell out symbols and abbreviations "
    "the way you would say them. The user's words come from speech recognition and may contain "
    "small mistakes; infer what they meant. Keep each reply to about three to six sentences "
    "so the conversation stays a back-and-forth; go longer only when the user asks for detail."
)
# The five best Kokoro voices by Kokoro's own quality grades (VOICES.md): A, A-, B-, B-, C+.
VOICES = ["af_heart", "af_bella", "af_nicole", "bf_emma", "af_sarah"]
PREVIEW_TEXT = "Hi, I'm Aria. This is how I sound when we talk. Ask me anything, and I'll tell you straight."

MIC_RATE = 24000
STT_RATE = 16000
TTS_RATE = 24000


SYCOPHANTIC_OPENER = re.compile(
    r"^\W*((you'?re (absolutely |totally |completely |so )?right|you are (absolutely )?right)( to (question|ask about|challenge|wonder about) (that|this|it))?|great question|"
    r"good question|what a great (question|point)|good point|great point|excellent (question|point))[\s,.!:;\u2014-]*",
    re.I)
_EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿️‍]+")


def to_ascii_quotes(s: str) -> str:
    s = re.sub(r"\s*[—–]\s*", ", ", s)
    s = _EMOJI.sub("", s)
    return (s.replace("’", "'").replace("‘", "'").replace("“", '"')
             .replace("”", '"'))


THINK_OPEN = ("<think>", "<|channel>thought")
THINK_CLOSE = ("</think>", "<channel|>")


def clean_for_speech(s: str) -> str:
    s = re.sub(r"<think>.*?</think>", "", s, flags=re.S)
    s = re.sub(r"<\|channel>.*?<channel\|>", "", s, flags=re.S)
    s = re.sub(r"<\|?[a-z_\"]+\|?>", " ", s)  # any leftover special-token text such as <turn|>
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
    p.add_argument("--think-budget", type=int, default=256, help="max reasoning tokens when Think first is on")
    p.add_argument("--no-tools", dest="tools", action="store_false", help="conversation only")
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
    for _ in tts.generate("Hello there.", voice=args.voice, lang_code=args.voice[0]):
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
    # Hybrid reasoning models (Qwen3 8B/14B/30B, Gemma 4) accept enable_thinking; the 2507 Instruct models don't.
    _tpl = getattr(tokenizer, "chat_template", "") or ""
    can_think = ("<think>" in _tpl or "enable_thinking" in _tpl) and "Instruct-2507" not in args.llm
    TOOL_START = getattr(tokenizer, "tool_call_start", None) or "<tool_call>"

    memory = Memory(vault)
    net = Connectivity()
    vision = None  # created after the GPU worker exists

    def transcribe_file(wav_path: str) -> list:
        """Local Parakeet transcription of a temporary audio file (runs on the GPU thread)."""
        import wave as wavemod

        with wavemod.open(wav_path) as w:
            a = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
        res = stt.generate(mx.array(a), chunk_duration=120.0, overlap_duration=5.0)
        return [(float(s.start), s.text.strip()) for s in getattr(res, "sentences", []) if s.text.strip()]

    def base_prompt() -> str:
        """Constant across sessions (with the tool schema it is ~2.6k tokens, KV-cached)."""
        today = time.strftime("%A %d %B %Y")
        tz = time.strftime("%Z")
        return (SPOKEN_STYLE + ("\n\n" + TOOL_GUIDE if args.tools else "")
                + f"\n\nToday is {today} (time zone {tz}).")

    def build_messages(persona: str) -> list[dict]:
        """[personality + base + tools] [memory]. The personality must share the first system message
        with the tool instructions: as a separate system message the 4B model stops emitting proper
        tool calls (measured 6/8 vs 8/8). Memory changes only re-process the small second block;
        a personality change is pre-warmed in the background via /api/prime."""
        return [{"role": "system", "content": "Your personality and role:\n" + persona + "\n\n" + base_prompt()},
                {"role": "system", "content": memory.system_block()}]

    # One KV cache for the whole process: sessions run one at a time, so each new session only
    # trims back to the shared system-prompt prefix instead of prefilling ~2k tokens again.
    shared = {"cache": make_prompt_cache(lm), "tokens": []}

    def prime(msgs: list) -> None:
        sys_tokens = list(tokenizer.apply_chat_template(
            msgs, tools=TOOLS if args.tools else None, add_generation_prompt=False,
            tokenize=True, enable_thinking=False))
        common = 0
        for x, y in zip(shared["tokens"], sys_tokens):
            if x != y:
                break
            common += 1
        if len(shared["tokens"]) > common:
            trim_prompt_cache(shared["cache"], len(shared["tokens"]) - common)
        if common < len(sys_tokens):
            for _ in stream_generate(lm, tokenizer, sys_tokens[common:], max_tokens=1,
                                     prompt_cache=shared["cache"]):
                pass
        off = shared["cache"][0].offset
        shared["tokens"] = sys_tokens[:off]

    t_prime = time.time()
    last_persona = {"text": args.text_prompt.strip() or DEFAULT_PERSONA}
    prime(build_messages(last_persona["text"]))
    emit("STATUS", f"System prompt primed ({len(shared['tokens'])} tokens) in {time.time() - t_prime:.1f}s")
    lock = asyncio.Lock()
    ui_dir = Path(args.ui_dir)
    # One thread owns all GPU (MLX) work; VAD runs on the CPU stream next to it.
    gpu_jobs: queue.Queue = queue.Queue()

    def gpu_worker_main():
        # MLX streams are per thread: this thread gets its own GPU stream.
        with mx.stream(mx.new_stream(mx.gpu)):
            while True:
                fn = gpu_jobs.get()
                try:
                    fn()
                except Exception as exc:  # keep the worker alive
                    emit("ERROR", f"model job failed: {exc!r}")

    threading.Thread(target=gpu_worker_main, name="air-gpu", daemon=True).start()
    vision = Vision(emit, gpu_jobs)

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
        if voice not in VOICES:
            voice = args.voice
        persona = (request.query.get("persona") or args.text_prompt).strip() or DEFAULT_PERSONA
        personality = (request.query.get("personality") or "").strip()[:40]
        # "Think first": let a hybrid model reason before answering (hidden from speech).
        think = request.query.get("think") == "1" and can_think
        web_on = request.query.get("web", "1") != "0"   # online fact-check (on by default)
        memory.reload()  # pick up edits the owner made to Profile.md in Obsidian
        last_persona["text"] = persona
        recorder = SessionRecorder(vault, voice, persona, mode="Aria", model_id=model_ids,
                                   assistant="Aria", user_side=True)
        recorder.personality = personality
        messages: list[dict] = build_messages(persona)
        st = {
            "gen": 0,                 # bumped to cancel the reply being generated
            "play_until": 0.0,        # monotonic time when queued audio finishes playing
            "busy": False,            # a reply is being generated
            "closed": False,
            "cache": shared["cache"],      # one KV cache reused across sessions
            "cache_tokens": shared["tokens"],
            "latencies": [],
            "labels": {},             # tool item id -> title, for spoken confirmations
            "recalled": set(),        # session notes already pulled into this conversation
        }
        web = WebSession(net, vault, transcribe_audio=transcribe_file)
        recorder.web_log = web.log
        out_q: asyncio.Queue = asyncio.Queue()

        def send(kind: int, payload: bytes = b"") -> None:
            loop.call_soon_threadsafe(out_q.put_nowait, bytes([kind]) + payload)

        def event(**payload) -> None:
            send(9, json.dumps(payload, ensure_ascii=False).encode())

        def set_state(s: str) -> None:
            send(7, s.encode())

        # ---------------- VAD (CPU stream, its own thread) ----------------
        mic_q: queue.Queue = queue.Queue()
        utter: list = []          # 24 kHz float frames of the current user turn
        pre: list = []            # rolling 300 ms pre-roll
        turn = {"speaking": False, "speech_ms": 0.0, "silence_ms": 0.0, "end_t": 0.0}

        def assistant_audible() -> bool:
            return st["busy"] or time.monotonic() < st["play_until"]

        def barge_in():
            st["gen"] += 1
            st["play_until"] = 0.0
            send(6)

        def end_turn(manual: bool = False):
            audio24 = np.concatenate(utter) if utter else np.zeros(0, np.float32)
            utter.clear()
            # resample the whole turn once (per-chunk resampling leaves clicks that hurt STT)
            if not manual and audio24.size:
                # drop most of the trailing pause we waited through; keep ~150 ms
                keep = audio24.shape[0] - int(24000 * max(0.0, args.silence_ms / 1000.0 - 0.15))
                audio24 = audio24[: max(keep, 1)]
            audio = resample_poly(audio24, 2, 3).astype(np.float32) if audio24.size else audio24
            turn["speaking"] = False
            turn["speech_ms"] = 0.0
            emit("TURN", f"end of turn: {audio.shape[0] / STT_RATE:.2f}s of audio{' (manual)' if manual else ''}")
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
            frame = 480  # 20 ms at 24 kHz
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
                        if len(pre) > 8:  # 160 ms pre-roll
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
        def run_tool(name: str, targs: dict, confirm: str) -> dict:
            clean = {k: v for k, v in targs.items() if not k.startswith("_")}
            t = time.strftime("%H:%M:%S")
            set_state("checking" if name in ("web_search", "read_page", "extract_page", "web_search_and_open",
                                             "get_video_transcript", "transcribe_video_audio") else "working")
            event(t="tool", phase="start", name=name)
            if name in VISION_TOOLS:
                result = look(name, clean)
            elif name in WEB_TOOLS:
                try:
                    if name == "save_as":
                        result = web.save_as(clean.get("format", ""), clean.get("title"), clean.get("content"))
                    elif name == "open_source":
                        result = web.open_source(int(clean.get("number") or 1))
                    else:
                        arg = clean.get("query") or clean.get("url") or ""
                        result = getattr(web, name)(arg)
                except Exception as exc:
                    result = {"ok": False, "error": f"{name} failed: {exc}"}
            elif name in TOOL_NAMES:
                result = call_app_tool(name, clean)
            else:
                result = {"ok": False, "error": f"unknown tool {name}"}
            # remember titles for ids, so confirmations can say "Dentist" instead of an id
            for item in (result.get("events") or []) + (result.get("reminders") or []):
                if isinstance(item, dict) and item.get("id"):
                    st["labels"][item["id"]] = item.get("title", "")
            summary = result.get("summary") or result.get("error") or json.dumps(result)[:200]
            if name in VISION_TOOLS and result.get("ok"):
                summary = f"looked at {'screen' if name == 'look_at_screen' else 'image'} ({result.get('looked_at', '')})"
            recorder.tool_log.append({"time": t, "tool": name, "args": clean, "confirm": confirm,
                                      "result": ("ok: " if result.get("ok") else "failed: ") + str(summary)})
            emit("TOOLCALL", f"{name} {json.dumps(clean)} -> {str(summary)[:200]}")
            event(t="tool", phase="end", name=name, ok=bool(result.get("ok")), summary=str(summary)[:160])
            if name in WEB_TOOLS and result.get("ok") and web.last_sources:
                event(t="sources", items=[{"title": s_["title"], "url": s_["url"]} for s_ in web.last_sources[:6]])
            if name == "save_as" and result.get("ok") and result.get("path"):
                event(t="file", path=result["path"])
            set_state("thinking")
            return result

        def transcribe(audio) -> str:
            rng = np.random.default_rng()
            dith = (rng.standard_normal(audio.shape[0]) * 3e-4).astype(np.float32)
            text_ = stt.generate(mx.array(audio + dith)).text.strip()
            if not text_ and audio.shape[0] > STT_RATE * 0.5:
                # Parakeet can return nothing for a very short word padded with silence: retry tighter.
                core = audio[int(STT_RATE * 0.12): max(int(STT_RATE * 0.3), audio.shape[0] - int(STT_RATE * 0.3))]
                text_ = stt.generate(mx.array(core + dith[: core.shape[0]])).text.strip()
            return text_

        def net_hint() -> str:
            if not args.tools:
                return ""
            if not net.online:
                return ("(Offline right now: web tools are unavailable. Answer from your own knowledge; for "
                        "factual claims, mention briefly that you couldn't verify online.)")
            if web_on:
                return ("(Online: for factual claims such as facts, figures, dates, people or recent events, "
                        "call web_search first, then say briefly what the answer is based on.)")
            return "(Online lookups are turned off; use web tools only if the user explicitly asks.)"

        def look(name: str, a: dict) -> dict:
            """Capture (app) -> describe (Qwen3.5-9B, loaded on demand) -> discard (app)."""
            if name == "look_at_screen":
                cap = call_app_tool("capture_screen", {"scope": a.get("scope") or "screen"}, timeout=30)
            else:
                path = str(a.get("path") or "").strip()
                source = "file" if path else (a.get("source") if a.get("source") in ("clipboard", "finder") else "clipboard")
                cap = call_app_tool("get_image", {"source": source, "path": path}, timeout=30)
            if not cap.get("ok"):
                return cap
            event(t="looking", app=cap.get("app", ""), window=cap.get("window", ""))
            where = " - ".join(x for x in (cap.get("app"), cap.get("window")) if x)
            try:
                res = vision.describe(cap["path"], str(a.get("question", "")),
                                      context=f"Front app and window: {where}" if where else "", ocr=cap.get("ocr", ""))
            except Exception as exc:
                res = {"ok": False, "error": f"I couldn't analyse the image: {exc}"}
            finally:
                kept = call_app_tool("discard_capture", {"path": cap["path"], "save": bool(a.get("save"))}, timeout=10)
            emit("VISION", f"{name} ({where or cap.get('source', '')}): {res.get('seconds')}s, load {res.get('load_s')}s, "
                           f"peak {res.get('peak_gb')}GB")
            res["looked_at"] = where or cap.get("source", "image")
            if kept.get("saved"):
                res["saved_screenshot"] = kept["saved"]
                event(t="file", path=kept["saved"])
            return res

        def with_recall(text_: str) -> str:
            """Attach older conversations that match this turn (BM25) and the network state. Added to
            the user message, after the cached prefix, so the KV cache stays valid."""
            hint = net_hint()
            hits = [h for h in memory.recall(text_) if h["name"] not in st["recalled"]]
            if not hits:
                return f"{text_}\n\n{hint}" if hint else text_
            for h in hits:
                st["recalled"].add(h["name"])
            emit("MEMORY", "recalled " + ", ".join(h["name"] for h in hits))
            notes = "\n".join(f"- {h['date']}: {h['summary']}" for h in hits)
            return f"{text_}\n\n(Memory that may be relevant, from earlier conversations:\n{notes})" + (f"\n{hint}" if hint else "")

        def reply(audio, t_end: float, gen_id: int, typed: str | None = None):
            def cancelled() -> bool:
                return gen_id != st["gen"] or st["closed"]

            spoken: list[str] = []
            first_audio = None
            marks: dict = {}
            perf = {"tts_s": 0.0, "audio_s": 0.0, "tokens": 0, "llm_s": 0.0, "new_tokens": 0}

            def speak(chunk: str) -> bool:
                nonlocal first_audio
                chunk = clean_for_speech(chunk)
                if not spoken:
                    # Anti-sycophancy guard: never open a reply with flattery or reflexive agreement.
                    chunk = SYCOPHANTIC_OPENER.sub("", chunk).strip()
                    chunk = chunk[:1].upper() + chunk[1:]
                if not chunk:
                    return True
                if "chunk1" not in marks:
                    marks["chunk1"] = time.monotonic()
                if "hold" in marks and len(spoken) == marks["hold"] and "answer_start" not in marks:
                    marks["answer_start"] = time.monotonic()
                t_tts = time.monotonic()
                for res in tts.generate(chunk, voice=voice, lang_code=voice[0]):
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

            guard = {"hit": False}

            def generate(live: bool = True, check_claims: bool = False) -> tuple[str, list[dict]]:
                """Stream one assistant message; speak it sentence by sentence.
                Returns (text, tool_calls). Text after a <tool_call> tag is not spoken."""
                prompt = list(tokenizer.apply_chat_template(
                    messages, tools=TOOLS if args.tools else None, add_generation_prompt=True, tokenize=True,
                    enable_thinking=think))
                cached = st["cache_tokens"]
                common = 0
                for x, y in zip(cached, prompt):
                    if x != y:
                        break
                    common += 1
                common = min(common, len(prompt) - 1)
                if len(cached) > common:
                    trim_prompt_cache(st["cache"], len(cached) - common)
                feed = prompt[common:]
                perf["new_tokens"] += len(feed)
                sampler = make_sampler(temp=args.temp, top_p=0.9)
                full = ""
                buf = ""
                in_think = False
                in_tool = False
                t0 = time.monotonic()
                tts_before = perf["tts_s"]
                segments = [feed]
                think_tokens = 0
                while segments:
                    seg = segments.pop(0)
                    for resp in stream_generate(lm, tokenizer, seg, max_tokens=args.max_tokens,
                                                sampler=sampler, prompt_cache=st["cache"]):
                        perf["tokens"] += 1
                        if "tool_end" in marks and "r2_tok1" not in marks:
                            marks["r2_tok1"] = time.monotonic()
                            marks["r2_prompt"] = len(seg)
                        full += resp.text
                        if cancelled():
                            break
                        if in_tool:
                            continue
                        piece = resp.text
                        if in_think and not any(c in piece for c in THINK_CLOSE):
                            think_tokens += 1
                            if think_tokens >= args.think_budget:
                                # Thinking budget used up: close the reasoning and make it answer.
                                close = ("\n\nThat's enough thinking; answer now.\n"
                                         + ("<channel|>" if "<|channel>" in full else "</think>\n\n"))
                                full += close
                                marks["think_s"] = marks.get("think_s", 0.0) + time.monotonic() - marks.get("think_start", time.monotonic())
                                in_think = False
                                segments.append(tokenizer.encode(close, add_special_tokens=False))
                                break
                        if any(o in piece for o in THINK_OPEN) or (piece.strip() == "thought" and full.endswith("<|channel>thought")):
                            in_think = True
                            marks.setdefault("think_start", time.monotonic())
                        if in_think and live and not spoken and not marks.get("filler") and \
                                time.monotonic() - marks.get("think_start", time.monotonic()) > 1.2:
                            marks["filler"] = True
                            speak("Let me think.")
                        if in_think and any(c in piece for c in THINK_CLOSE):
                            marks["think_s"] = marks.get("think_s", 0.0) + time.monotonic() - marks.get("think_start", time.monotonic())
                        if in_think:
                            closer = next((c for c in THINK_CLOSE if c in piece), None)
                            if closer:
                                in_think = False
                                piece = piece.split(closer, 1)[1]
                            else:
                                continue
                        buf += piece
                        if TOOL_START in buf:
                            buf, _ = buf.split(TOOL_START, 1)
                            in_tool = True
                        if not live:
                            continue
                        while True:
                            chunk, buf = pop_sentence(buf, first=not spoken or len(spoken) == marks.get("hold", -1))
                            if chunk is None:
                                break
                            if args.tools and looks_like_tool_text(chunk):
                                live = False  # a tool call written as text: parse it, never speak it
                                break
                            if check_claims and claims_action(chunk):
                                # Would claim an action that no tool performed: stop speaking here.
                                guard["hit"] = True
                                live = False
                                break
                            if not speak(chunk):
                                break
                        if cancelled():
                            break
                    if cancelled():
                        break
                if live and not cancelled() and buf.strip():
                    if args.tools and looks_like_tool_text(buf):
                        pass
                    elif check_claims and claims_action(buf):
                        guard["hit"] = True
                    else:
                        speak(buf)
                perf["llm_s"] += (time.monotonic() - t0) - (perf["tts_s"] - tts_before)
                offset = st["cache"][0].offset if hasattr(st["cache"][0], "offset") else None
                gen_tokens = tokenizer.encode(full, add_special_tokens=False) if full else []
                st["cache_tokens"] = (prompt + gen_tokens)[:offset] if offset is not None else []
                if offset is None:
                    st["cache"] = shared["cache"] = make_prompt_cache(lm)
                shared["tokens"] = st["cache_tokens"]
                calls = parse_tool_calls(full)
                text = re.sub(r"<think>.*?</think>|<\|channel>.*?<channel\|>", "", full, flags=re.S)
                text = re.sub(r"<\|?[a-z_\"]+\|?>", "", text.split(TOOL_START, 1)[0]).strip()
                return text, calls

            def tool_message(payload: dict) -> dict:
                return {"role": "tool", "content": json.dumps(payload, ensure_ascii=False)[:4000]}

            try:
                t_stt = time.monotonic()
                text = typed if typed is not None else transcribe(audio)
                stt_ms = (time.monotonic() - t_stt) * 1000
                marks["stt_done"] = time.monotonic()
                if not text or cancelled():
                    emit("TURN", f"skipped: text={text!r} cancelled={cancelled()}")
                    set_state("listening")
                    return
                send(5, text.encode())
                spoke_at = (t_end - (audio.shape[0] / STT_RATE if audio is not None else 0)) - recorder.start_mono
                recorder.add_segment(spoke_at, "You", text)

                pending = st.pop("pending", None)
                confirmed_ok = False
                if pending is not None:
                    verdict = classify_reply(text)
                    event(t="confirm_done", answer=verdict)
                    if verdict == "yes":
                        result = run_tool(pending["name"], pending["args"], f'confirmed ("{text}")')
                        confirmed_ok = bool(result.get("ok"))
                        messages.append(tool_message({"user_said": text, "confirmed": True, "result": result}))
                    else:
                        recorder.tool_log.append({"time": time.strftime("%H:%M:%S"), "tool": pending["name"],
                                                  "args": {k: v for k, v in pending["args"].items() if not k.startswith("_")},
                                                  "confirm": f'declined ("{text}")' if verdict == "no" else f'not confirmed ("{text}")',
                                                  "result": "not run"})
                        emit("TOOLCALL", f"{pending['name']} declined by user: {text}")
                        messages.append(tool_message({"user_said": text, "confirmed": False,
                                                      "result": "Not run. Nothing was changed."}))
                        if verdict == "unclear":
                            # They moved on to something else: handle it as a new request.
                            messages.append({"role": "user", "content": with_recall(text)})
                else:
                    messages.append({"role": "user", "content": with_recall(text)})

                t_llm = time.monotonic()
                said_parts: list[str] = []
                used_tool = False
                nudged = False
                acted = confirmed_ok

                def say(text_: str) -> None:
                    before_ = len(spoken)
                    rest = text_
                    while True:
                        chunk, rest = pop_sentence(rest, first=not spoken)
                        if chunk is None or not speak(chunk):
                            break
                    if rest.strip() and not cancelled():
                        speak(rest)
                    said_parts.extend(spoken[before_:])

                for _round in range(5):  # at most a few tool calls per turn
                    # The first answer streams live for speed. After a tool has run, the follow-up is
                    # checked before it is spoken, so a claim that something was done can be caught.
                    # Stream live; when no action has run yet, each sentence is checked before it is
                    # spoken so a claim like "I've closed it" can't be voiced without a tool call.
                    guard["hit"] = False
                    before = len(spoken)
                    reply_text, calls = generate(True, check_claims=bool(args.tools and not acted))
                    live = True
                    said_parts += spoken[before:]
                    if cancelled():
                        break
                    if calls:
                        if not live and reply_text:
                            say(reply_text)
                    else:
                        # A claim is only suspicious if no action tool actually ran in this turn.
                        suspicious = args.tools and not acted and (
                            guard["hit"] or claims_action(reply_text) or (used_tool and announces_action(reply_text)))
                        if suspicious and not nudged:
                            nudged = True
                            emit("TOOLCALL", f"nudge: reply announced an action without a tool call: {reply_text[:120]!r}")
                            if live and claims_action(reply_text):
                                say("Sorry, I haven't actually done that yet.")
                            messages.append({"role": "assistant", "content": reply_text})
                            messages.append({"role": "user", "content": NUDGE})
                            used_tool = True  # keep the next answer buffered
                            continue
                        if suspicious and nudged and claims_action(reply_text):
                            emit("TOOLCALL", "still no tool call after nudge: said so honestly")
                            say(HONEST)
                            messages.append({"role": "assistant", "content": HONEST})
                            break
                        if not live and reply_text:
                            say(reply_text)
                        if reply_text:
                            messages.append({"role": "assistant", "content": reply_text})
                        break
                    used_tool = True
                    call = calls[0]
                    name, targs = call["name"], dict(call["arguments"])
                    messages.append({"role": "assistant", "content": reply_text,
                                     "tool_calls": [{"type": "function",
                                                     "function": {"name": name, "arguments": targs}}]})
                    if name in NEEDS_CONFIRMATION:
                        for key in ("event_id", "reminder_id"):
                            if targs.get(key) in st["labels"]:
                                targs["_label"] = st["labels"][targs[key]]
                        st["pending"] = {"name": name, "args": targs}
                        event(t="confirm", tool=name, text=describe(name, targs).split(" Should I go ahead")[0])
                        say(describe(name, targs))
                        emit("TOOLCALL", f"{name} {json.dumps(call['arguments'])} awaiting confirmation")
                        break
                    hold = ON_HOLD.get(name)
                    if hold and not spoken:
                        say(hold)
                        marks["hold"] = len(spoken)  # the answer proper starts after this
                    marks.setdefault("r1_end", time.monotonic())
                    result = run_tool(name, targs, "not needed (read-only or navigation)")
                    marks.setdefault("tool_end", time.monotonic())
                    if name in ACTION_TOOLS and result.get("ok"):
                        acted = True
                    messages.append(tool_message(result))

                said = " ".join(said_parts).strip()
                interrupted = cancelled() and not st["closed"]
                if said:
                    recorder.add_segment((first_audio or time.monotonic()) - recorder.start_mono, "Aria",
                                         said + (" [interrupted]" if interrupted else ""))
                if interrupted and messages and messages[-1]["role"] == "user":
                    messages.append({"role": "assistant", "content": (said + " ...") if said else "..."})
                if first_audio is not None:
                    lat = first_audio - t_end
                    st["latencies"].append(lat)
                    llm_s = max(perf["llm_s"], 1e-6)
                    emit("LATENCY", f"end-of-speech to first audio {lat:.2f}s = wait for pause "
                                    f"{t_stt - t_end:.2f} + stt {stt_ms / 1000:.2f} + llm to first clause "
                                    f"{marks.get('chunk1', first_audio) - marks['stt_done']:.2f} + tts "
                                    f"{first_audio - marks.get('chunk1', first_audio):.2f} (prompt "
                                    f"{perf['new_tokens']} new tokens, {perf['tokens']} tokens, llm "
                                    f"{perf['tokens'] / llm_s:.1f} tok/s, tts {perf['tts_s']:.1f}s for "
                                    f"{perf['audio_s']:.1f}s audio, total {time.monotonic() - t_llm:.1f}s"
                                    f"{', thought %.1fs' % marks['think_s'] if 'think_s' in marks else ''}"
                                    f"{', answer after tools at %.2fs' % (marks['answer_start'] - t_end) if 'answer_start' in marks else ''}"
                                    f"{' [tool call decided %.2fs, tool done %.2fs, first answer token %.2fs after %d new prompt tokens]' % (marks['r1_end'] - t_end, marks['tool_end'] - t_end, marks['r2_tok1'] - t_end, marks['r2_prompt']) if 'r2_tok1' in marks else ''}"
                                    f", net={'online' if net.online else 'offline'})"
                                    f"{' interrupted' if interrupted else ''}")
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

        def prime_session():
            prime(messages)
            st["cache_tokens"] = shared["tokens"]

        gpu_jobs.put(prime_session)
        emit("STATUS", f"session start mode=Aria voice={voice} think={think}")
        await ws.send_bytes(b"\x00")
        set_state("listening")
        send_task = asyncio.create_task(sender())
        save_task = asyncio.create_task(autosave())
        carry = np.zeros(0, np.float32)
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.BINARY and msg.data and msg.data[0] == 1:
                    pcm = np.frombuffer(msg.data[1:], dtype="<i2").astype(np.float32) / 32768.0
                    mic_q.put(pcm)
                elif msg.type == aiohttp.WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                    except ValueError:
                        continue
                    if data.get("type") == "end_turn":
                        mic_q.put("END")
                    elif data.get("type") == "stop_speaking":
                        barge_in()
                    elif data.get("type") in ("confirm", "say"):
                        # A tapped Confirm/Cancel or a typed turn: handled like a spoken one, minus STT.
                        typed = {"yes": "Yes.", "no": "No."}.get(data.get("answer"), "") if data["type"] == "confirm" \
                            else str(data.get("text", ""))[:2000]
                        if typed.strip():
                            if assistant_audible():
                                barge_in()
                            gen_id = st["gen"] + 1
                            st["gen"] = gen_id
                            st["busy"] = True
                            set_state("thinking")
                            gpu_jobs.put(lambda t_=typed, g_=gen_id, e_=time.monotonic(): reply(None, e_, g_, typed=t_))
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
                user_words = sum(len(t.split()) for _, sp, t in recorder.segments if sp == "You")
                if user_words >= 8:
                    gpu_jobs.put(lambda p=path: remember(p))
            lats = st["latencies"]
            if lats:
                emit("STATUS", f"session end: {len(lats)} replies, latency median "
                               f"{sorted(lats)[len(lats) // 2]:.2f}s, max {max(lats):.2f}s, "
                               f"peak {mx.get_peak_memory() / 1e9:.2f}GB")
            else:
                emit("STATUS", "session end")
            await send_task

    def remember(note: Path) -> None:
        """After a session: summary into the note, new facts into Profile.md, then re-prime."""
        t0 = time.time()
        try:
            prompt = build_summary_prompt(vault, transcript_of(note))
            chat = tokenizer.apply_chat_template([{"role": "user", "content": prompt}],
                                                 add_generation_prompt=True, tokenize=False,
                                                 enable_thinking=False)
            out = "".join(r.text for r in stream_generate(lm, tokenizer, chat, max_tokens=500,
                                                          sampler=make_sampler(temp=0.2)))
            data = parse_json_object(out)
            summary = str(data.get("summary", "")).strip()
            if summary:
                add_summary_to_note(note, summary)
            n = merge_profile(vault, data, data.get("resolved_threads") or [])
            write_index(vault)
            memory.reload()
            emit("MEMORY", f"saved summary and {n} profile updates in {time.time() - t0:.1f}s")
            emit("SESSION_SAVED", str(note))
        except Exception as exc:
            emit("ERROR", f"memory update failed: {exc!r}")
        try:
            t1 = time.time()
            prime(build_messages(last_persona["text"]))  # ready for the next session
            emit("STATUS", f"re-primed for next session in {time.time() - t1:.1f}s")
        except Exception as exc:
            emit("ERROR", f"re-prime failed: {exc!r}")

    async def handle_root(_):
        resp = web.FileResponse(ui_dir / "index.html")
        resp.headers["Cache-Control"] = "no-store"
        return resp

    previews: dict[str, bytes] = {}

    async def handle_preview(request):
        """A short sample of a voice as WAV, for the picker's play buttons."""
        import io
        import wave as wavemod

        v = request.query.get("voice", "")
        if v not in VOICES:
            return web.Response(status=404)
        if v not in previews:
            loop = asyncio.get_running_loop()
            fut = loop.create_future()

            def job():
                try:
                    pcm = np.concatenate([np.array(r.audio).reshape(-1)
                                          for r in tts.generate(PREVIEW_TEXT, voice=v, lang_code=v[0])])
                    loop.call_soon_threadsafe(fut.set_result, pcm)
                except Exception as exc:  # pragma: no cover
                    loop.call_soon_threadsafe(fut.set_exception, exc)

            gpu_jobs.put(job)
            pcm = await fut
            buf = io.BytesIO()
            with wavemod.open(buf, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(TTS_RATE)
                w.writeframes((np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes())
            previews[v] = buf.getvalue()
        return web.Response(body=previews[v], content_type="audio/wav",
                            headers={"Cache-Control": "no-store"})

    async def handle_prime(request):
        """Pre-warm the KV cache for a newly picked personality so the next first reply stays fast."""
        persona = (request.query.get("persona") or "").strip()
        if persona and not lock.locked():
            last_persona["text"] = persona
            gpu_jobs.put(lambda p=persona: prime(build_messages(p)))
        return web.json_response({"ok": True})

    async def handle_status(_):
        return web.json_response({"ready": True, "busy": lock.locked(), "mode": "aria", "can_think": can_think,
                                  "online": net.online,
                                  "voices": VOICES})

    app = web.Application()
    app.router.add_get("/", handle_root)
    app.router.add_get("/api/chat", handle_chat)
    app.router.add_get("/api/status", handle_status)
    app.router.add_post("/api/prime", handle_prime)
    app.router.add_get("/api/preview", handle_preview)
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
