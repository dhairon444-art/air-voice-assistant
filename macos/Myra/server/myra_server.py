"""Myra model server.

Runs PersonaPlex-MLX as a child process of Myra.app:

* binds to 127.0.0.1 only, on a free port chosen by the OS
* reads every model file from the local Hugging Face cache (no network)
* streams raw 16-bit PCM over a WebSocket to the app's own web UI
* writes each conversation to the "Myra" Obsidian vault
* exits as soon as its parent app goes away (stdin EOF or parent PID change)

Lines starting with MYRA_STATUS / MYRA_READY / MYRA_ERROR on stdout are read by
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
    "You are Myra, a warm and curious companion. Listen carefully, answer clearly "
    "and keep the conversation natural."
)
VOICES = [
    "NATF0", "NATF1", "NATF2", "NATF3",
    "NATM0", "NATM1", "NATM2", "NATM3",
    "VARF0", "VARF1", "VARF2", "VARF3", "VARF4",
    "VARM0", "VARM1", "VARM2", "VARM3", "VARM4",
]
SAMPLE_RATE = 24000
FRAME_SIZE = 1920
GAP_NEW_LINE_S = 3.0


def emit(kind: str, msg: str = "") -> None:
    print(f"MYRA_{kind} {msg}".rstrip(), flush=True)


# ---------------------------------------------------------------- lifetime ---

_active_recorders: set["SessionRecorder"] = set()
_shutdown_lock = threading.Lock()


def shutdown(reason: str) -> None:
    """Save any open session, then exit immediately (no lingering threads)."""
    if not _shutdown_lock.acquire(blocking=False):
        return
    try:
        emit("STATUS", f"shutting down ({reason})")
        for rec in list(_active_recorders):
            try:
                rec.finish()
            except Exception as exc:  # pragma: no cover - best effort
                emit("ERROR", f"could not save session: {exc}")
    finally:
        os._exit(0)


def watch_parent(parent_pid: int | None) -> None:
    """Exit when the app dies, even on force quit / crash (SIGKILL)."""

    def stdin_watch():
        try:
            while sys.stdin.buffer.read(1024):
                pass
        except Exception:
            pass
        shutdown("parent closed pipe")

    def pid_watch():
        while True:
            time.sleep(1.0)
            if parent_pid is not None and os.getppid() != parent_pid:
                shutdown("parent exited")

    threading.Thread(target=stdin_watch, daemon=True).start()
    threading.Thread(target=pid_watch, daemon=True).start()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda s, f: shutdown(f"signal {s}"))


# ------------------------------------------------------------------- vault ---

BRIGHT_SNIPPET_NAME = "myra-bright-diagrams"
BRIGHT_SNIPPET = """/* Bright Mermaid charts with dark labels (Myra vault). */
.mermaid .pieTitleText, .mermaid .legend text { fill: var(--text-normal) !important; }
.mermaid .slice { fill: #132034 !important; }
"""


def fmt_duration(seconds: float) -> str:
    seconds = int(round(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m {s:02d}s"
    return f"{m}m {s:02d}s"


def ensure_vault(vault: Path) -> None:
    (vault / "Sessions").mkdir(parents=True, exist_ok=True)
    obs = vault / ".obsidian"
    snippets = obs / "snippets"
    if not obs.exists():
        snippets.mkdir(parents=True, exist_ok=True)
        (snippets / f"{BRIGHT_SNIPPET_NAME}.css").write_text(BRIGHT_SNIPPET, encoding="utf-8")
        (obs / "appearance.json").write_text(
            json.dumps({"enabledCssSnippets": [BRIGHT_SNIPPET_NAME]}, indent=2), encoding="utf-8"
        )
        (obs / "app.json").write_text(json.dumps({"alwaysUpdateLinks": True}, indent=2), encoding="utf-8")
    if not (vault / "Myra Index.md").exists():
        write_index(vault)


_FM_RE = re.compile(r"^---\n(.*?)\n---\n", re.S)


def read_frontmatter(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    m = _FM_RE.match(text)
    out: dict[str, str] = {}
    if not m:
        return out
    for line in m.group(1).splitlines():
        if ":" in line and not line.startswith(" "):
            key, val = line.split(":", 1)
            val = val.strip()
            if val.startswith('"'):
                try:
                    val = json.loads(val)
                except json.JSONDecodeError:
                    pass
            out[key.strip()] = val
    return out


def write_index(vault: Path) -> None:
    sessions = sorted((vault / "Sessions").rglob("*.md"), key=lambda p: p.name, reverse=True)
    rows = []
    voices: dict[str, int] = {}
    total = 0
    for p in sessions:
        fm = read_frontmatter(p)
        rel = p.relative_to(vault).with_suffix("").as_posix()
        try:
            label = datetime.strptime(p.stem[:15], "%Y-%m-%d %H%M").strftime("%a %d %b %Y, %H:%M")
        except ValueError:
            label = p.stem
        voice = fm.get("voice", "")
        voices[voice or "unknown"] = voices.get(voice or "unknown", 0) + 1
        try:
            total += int(fm.get("duration_seconds", "0"))
        except ValueError:
            pass
        persona = fm.get("persona", "").replace("|", "/").replace("\n", " ")
        if len(persona) > 60:
            persona = persona[:57] + "..."
        rows.append(
            f"| [[{rel}\\|{label}]] | {fm.get('duration', '')} | {voice} | {persona} |"
        )

    lines = [
        "---",
        "tags: [myra, index]",
        "---",
        "# Myra Index",
        "",
        "Every conversation with Myra, newest first. Myra.app rewrites this note after each session.",
        "",
        f"**{len(sessions)} session{'' if len(sessions) == 1 else 's'}** · **{fmt_duration(total)}** of conversation in total.",
        "",
    ]
    if voices and sessions:
        palette = ["#38BDF8", "#34D399", "#FBBF24", "#A78BFA", "#FB7185", "#F472B6"]
        theme = {"background": "transparent", "pieTitleTextColor": "#132034",
                 "pieSectionTextColor": "#132034", "pieLegendTextColor": "#132034",
                 "pieStrokeColor": "#132034"}
        for i, c in enumerate(palette * 2):
            theme[f"pie{i + 1}"] = c
        lines += [
            "```mermaid",
            "%%{init: " + json.dumps({"theme": "base", "themeVariables": theme}) + "}%%",
            "pie showData title Sessions by voice",
        ]
        for v, n in sorted(voices.items(), key=lambda kv: -kv[1]):
            lines.append(f'    "{v}" : {n}')
        lines += ["```", ""]
    lines += [
        "| Session | Duration | Voice | Persona |",
        "| --- | --- | --- | --- |",
    ]
    lines += rows or ["| _No sessions yet_ | | | |"]
    lines.append("")
    tmp = vault / ".Myra Index.md.tmp"
    tmp.write_text("\n".join(lines), encoding="utf-8")
    os.replace(tmp, vault / "Myra Index.md")


class SessionRecorder:
    """Collects Myra's streamed text and keeps a Markdown note up to date."""

    def __init__(self, vault: Path, voice: str, persona: str):
        self.vault = vault
        self.voice = voice
        self.persona = persona
        self.start = datetime.now()
        self.start_mono = time.monotonic()
        self.end: datetime | None = None
        self.segments: list[list] = []  # [offset_seconds, text]
        self.last_text_mono = 0.0
        self.lock = threading.Lock()
        self.finished = False
        folder = vault / "Sessions" / self.start.strftime("%Y") / self.start.strftime("%m")
        folder.mkdir(parents=True, exist_ok=True)
        base = self.start.strftime("%Y-%m-%d %H%M")
        path = folder / f"{base}.md"
        n = 2
        while path.exists():
            path = folder / f"{base} ({n}).md"
            n += 1
        self.path = path
        _active_recorders.add(self)

    def add_text(self, piece: str) -> None:
        now = time.monotonic()
        with self.lock:
            if not self.segments or now - self.last_text_mono > GAP_NEW_LINE_S:
                self.segments.append([now - self.start_mono, piece.lstrip()])
            else:
                self.segments[-1][1] += piece
            self.last_text_mono = now

    def has_text(self) -> bool:
        with self.lock:
            return any(seg[1].strip() for seg in self.segments)

    def render(self, final: bool) -> str:
        end = self.end or datetime.now()
        duration = (end - self.start).total_seconds()
        with self.lock:
            segs = [(o, t.strip()) for o, t in self.segments if t.strip()]
        words = sum(len(t.split()) for _, t in segs)
        title = self.start.strftime("%a %d %b %Y, %H:%M")
        fm = [
            "---",
            f"date: {self.start.strftime('%Y-%m-%d')}",
            f'start: "{self.start.strftime("%H:%M:%S")}"',
            f'end: "{end.strftime("%H:%M:%S")}"',
            f'duration: "{fmt_duration(duration)}"',
            f"duration_seconds: {int(round(duration))}",
            f"voice: {self.voice}",
            f"persona: {json.dumps(self.persona, ensure_ascii=False)}",
            f"status: {'complete' if final else 'in-progress'}",
            "tags: [myra, session]",
            "---",
        ]
        body = [
            f"# Myra session · {title}",
            "",
            "Back to [[Myra Index]]",
            "",
            "| Started | Ended | Duration | Voice | Words from Myra |",
            "| --- | --- | --- | --- | --- |",
            f"| {self.start.strftime('%H:%M:%S')} | {end.strftime('%H:%M:%S')} | "
            f"{fmt_duration(duration)} | {self.voice} | {words} |",
            "",
            "## Persona",
            "",
            "> " + self.persona.replace("\n", "\n> "),
            "",
            "## Transcript",
            "",
            "> [!note] Myra's side only",
            "> PersonaPlex streams the text of what Myra says. It does not transcribe "
            "your microphone, so your side of the conversation is not recorded.",
            "",
        ]
        if segs:
            for offset, text in segs:
                mm, ss = divmod(int(offset), 60)
                body.append(f"**[{mm:02d}:{ss:02d}] Myra:** {text}")
                body.append("")
        else:
            body.append("_Myra said nothing in this session._")
            body.append("")
        return "\n".join(fm + body)

    def save(self, final: bool = False) -> None:
        tmp = self.path.with_name("." + self.path.name + ".tmp")
        tmp.write_text(self.render(final), encoding="utf-8")
        os.replace(tmp, self.path)

    def finish(self) -> Path | None:
        if self.finished:
            return None
        self.finished = True
        _active_recorders.discard(self)
        self.end = datetime.now()
        duration = (self.end - self.start).total_seconds()
        if not self.has_text() and duration < 5:
            # Nothing worth keeping (e.g. connect + immediate disconnect).
            self.path.unlink(missing_ok=True)
            write_index(self.vault)
            return None
        self.save(final=True)
        write_index(self.vault)
        return self.path


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
    parser.add_argument("-q", "--quantized", type=int, choices=[4, 8], default=4)
    parser.add_argument("--group-size", type=int, default=64)
    parser.add_argument("--hf-repo", default="nvidia/personaplex-7b-v1")
    parser.add_argument("--voice", default="NATF2")
    parser.add_argument("--text-prompt", default=DEFAULT_PERSONA)
    parser.add_argument("--seed", type=int, default=42424242)
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
    emit("STATUS", f"Loading model weights ({size_gb:.1f} GB) and quantising to {args.quantized}-bit")
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
    mx.eval(model.parameters())
    emit("STATUS", f"Model loaded in {time.time() - t0:.0f}s")

    gen = models.LmGen(
        model=model,
        max_steps=args.steps + 1024,
        text_sampler=utils.Sampler(temp=0.7, top_k=25),
        audio_sampler=utils.Sampler(temp=0.8, top_k=250),
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

    lock = asyncio.Lock()
    ui_dir = Path(args.ui_dir)

    async def handle_chat(request: web.Request):
        ws = web.WebSocketResponse(max_msg_size=0)
        await ws.prepare(request)
        voice = request.query.get("voice") or args.voice
        if voice not in VOICES:
            voice = args.voice
        persona = (request.query.get("persona") or args.text_prompt).strip() or DEFAULT_PERSONA
        if lock.locked():
            await ws.send_bytes(b"\x03" + "Another conversation is already running.".encode())
            await ws.close()
            return ws

        voice_path = resolve_voice_prompt(None, voice, voice_dir)
        audio_tokenizer = rustymimi.StreamTokenizer(files["mimi"], num_codebooks=8)  # type: ignore
        text_q: queue.Queue[str] = queue.Queue()
        state = {"close": False, "steps": 0, "step_time": 0.0, "error": None}
        loop = asyncio.get_running_loop()
        prepared = asyncio.Event()
        recorder: SessionRecorder | None = None

        def model_worker():
            """All MLX work for a session runs on this one thread, so the event loop stays
            free to feed the Mimi encoder and send audio while the GPU computes."""
            try:
                seed_all(args.seed)
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
                state["step_time"] += time.perf_counter() - t_step

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
                    pcm = np.frombuffer(data[1:], dtype="<i2").astype(np.float32) / 32768.0
                    buf = np.concatenate((buf, pcm))
                    while buf.shape[-1] >= FRAME_SIZE:
                        audio_tokenizer.encode(buf[:FRAME_SIZE])  # non-blocking, runs on mimi's thread
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
                    while not text_q.empty():
                        piece = text_q.get_nowait()
                        if recorder is not None:
                            recorder.add_text(piece)
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
            emit("STATUS", f"session start voice={voice}")
            worker = threading.Thread(target=model_worker, name="myra-model", daemon=True)
            worker.start()
            await prepared.wait()
            if state["error"]:
                emit("STATUS", f"session failed: {state['error']}")
                await ws.send_bytes(b"\x03" + f"Could not start: {state['error']}".encode())
                await ws.close()
                await asyncio.to_thread(worker.join)
                return ws
            recorder = SessionRecorder(vault, voice, persona)
            await ws.send_bytes(b"\x00")
            try:
                await asyncio.gather(recv_loop(), send_loop(), autosave_loop())
            finally:
                state["close"] = True
                await asyncio.to_thread(worker.join, 5)
                path = recorder.finish()
                if path is not None:
                    emit("SESSION_SAVED", str(path))
                if state["steps"]:
                    ms = 1000 * state["step_time"] / state["steps"]
                    emit("STATUS", f"session end: {state['steps']} steps, {ms:.1f} ms/step "
                                   f"({80.0 / ms:.2f}x realtime)")
                else:
                    emit("STATUS", "session end")
        return ws

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
