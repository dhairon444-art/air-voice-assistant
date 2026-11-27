"""Headless action test for Aria's engine: does the brain CALL the tool, or narrate?

Starts aria_server.py on a scratch vault with AIR_DRY_OPEN=1 (links are logged, never opened) and its own
prompt-cache folder, sends typed turns over the WebSocket, and reports per request: tabs opened, tool calls,
words before acting, nudges and 'Do it' fallbacks. App-side tools (Reminders, Music...) get a fake OK.

    python tab_test.py --llm mlx-community/Qwen3-8B-4bit [--chat] [--think] [--out report.json]

GPU-heavy (loads a model): only run in an agreed test window.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

import aiohttp

HERE = Path(__file__).resolve().parent
SERVER = HERE.parent / "server" / "aria_server.py"
UI = HERE.parent / "Resources" / "ui"

CASES = [
    # (request, expected tabs or None, expected tool or None)
    ("Open LinkedIn.", 1, "open_url"),
    ("Open LinkedIn, Seek and Indeed.", 3, "open_url"),
    ("Uh can you open GitHub, Hacker News and Wikipedia?", 3, None),
    ("Open these ten sites: google.com, bing.com, duckduckgo.com, wikipedia.org, github.com, "
     "news.ycombinator.com, reddit.com, youtube.com, bbc.com and theguardian.com.", 10, "open_url"),
    ("Search for the best running shoes of 2026 and open the top 3 results.", 3, None),
    ("Remind me to call the dentist tomorrow at 10am.", 0, "add_reminder"),
    ("Pause the music.", 0, "music_control"),
    ("What's the weather like in Sydney today?", 0, None),
    ("Read this page and summarise it: https://en.wikipedia.org/wiki/Apple_M4", 0, "read_page"),
    ("Open the Notes app.", 0, "open_app"),
]


class Engine:
    def __init__(self, a):
        self.a = a
        self.proc = None
        self.port = None
        self.opened: list[str] = []
        self.toolcalls: list[str] = []
        self.app_tools: list[str] = []
        self.lines: list[str] = []      # every AIR_ line of the current turn
        self.all_lines: list[str] = []

    async def start(self):
        vault = Path(tempfile.mkdtemp(prefix="air-test-vault-"))
        cache = Path(tempfile.mkdtemp(prefix="air-test-cache-"))
        support = Path(tempfile.mkdtemp(prefix="air-test-support-"))
        env = dict(os.environ, AIR_SUPPORT_DIR=str(support), AIR_DEBUG_GEN="1", AIR_DRY_OPEN="1", AIR_PROMPT_CACHE_DIR=str(cache), HF_HUB_OFFLINE="1")
        cmd = [self.a.python, "-u", str(SERVER), "--vault", str(vault), "--ui-dir", str(UI), "--llm", self.a.llm]
        if self.a.chat:
            cmd.append("--chat")
        pid = getattr(self.a, "persona", "")
        if pid:
            presets = json.loads((HERE.parent / "Resources" / "personas.json").read_text())
            cmd += ["--text-prompt", next(p["text"] for p in presets if p["id"] == pid)]
        for flag in ("thinker", "thinker_draft", "route", "orch_cli"):
            v = getattr(self.a, flag, "")
            if v and flag != "orch_cli":
                cmd += ["--" + flag.replace("_", "-"), v]
        self.proc = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.PIPE,
                                                         stdout=asyncio.subprocess.PIPE,
                                                         stderr=asyncio.subprocess.PIPE, env=env)
        ready = asyncio.get_running_loop().create_future()
        asyncio.create_task(self._read_out(ready))
        asyncio.create_task(self._read_err())
        self.port = await asyncio.wait_for(ready, 600)
        print(f"engine ready on {self.port} (vault {vault})", flush=True)

    async def _read_out(self, ready):
        async for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip()
            if line.startswith("AIR_"):
                self.lines.append(line)
                self.all_lines.append(line)
            if line.startswith("AIR_READY ") and not ready.done():
                ready.set_result(int(line.split()[1]))
            elif line.startswith("AIR_TOOLCALL "):
                self.toolcalls.append(line[13:])
            elif line.startswith("AIR_TOOL "):
                _, cid, payload = line.split(" ", 2)
                self.app_tools.append(json.loads(payload)["name"])
                self.proc.stdin.write(f'TOOL_RESULT {cid} {json.dumps({"ok": True, "summary": "Done (test)"})}\n'.encode())
                await self.proc.stdin.drain()
            if self.a.verbose and line.startswith("AIR_"):
                print("   ", line[:200], flush=True)

    async def _read_err(self):
        async for raw in self.proc.stderr:
            line = raw.decode("utf-8", "replace").rstrip()
            if line.startswith("DRYOPEN "):
                self.opened.append(line[8:])

    async def turn(self, text: str, timeout: float = 150, ws=None) -> dict:
        if ws is not None:
            return await self._turn_on(ws, text, timeout)
        orch = getattr(self.a, "orch", "off")
        url = f"http://127.0.0.1:{self.port}/api/chat?think={'1' if self.a.think else '0'}&web=1&orch={orch}&mode={getattr(self.a, 'mode', '')}"
        async with aiohttp.ClientSession() as s, s.ws_connect(url, max_msg_size=0) as ws_:
            refused = await self._wait_ready(ws_)
            if refused:
                return {"request": text, "seconds": 0, "said": "", "tools": [], "app_tools": [], "opened": [],
                        "confirm": False, "doit": False, "nudged": False, "words_before_acting": 0, "toolcall_log": [],
                        "route": "", "first_audio": None, "latency": "", "refused": refused}
            r = await self._turn_on(ws_, text, timeout)
            await ws_.close()
        await asyncio.sleep(0.3)
        return r

    async def session(self):
        """A WebSocket for a multi-turn conversation (ready already received)."""
        orch = getattr(self.a, "orch", "off")
        url = f"http://127.0.0.1:{self.port}/api/chat?think={'1' if self.a.think else '0'}&web=1&orch={orch}&mode={getattr(self.a, 'mode', '')}"
        self._http = aiohttp.ClientSession()
        ws = await self._http.ws_connect(url, max_msg_size=0)
        refused = await self._wait_ready(ws)
        if refused:
            raise RuntimeError(f"session refused: {refused}")
        return ws

    async def _wait_ready(self, ws) -> str:
        """Wait for the engine's ready byte; returns why the session was refused, or ''."""
        while True:
            msg = await asyncio.wait_for(ws.receive(), 120)
            if msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.CLOSING, aiohttp.WSMsgType.ERROR):
                return "closed before ready"
            if msg.type == aiohttp.WSMsgType.BINARY and msg.data[:1] == b"\x03":
                return msg.data[1:].decode("utf-8", "replace")
            if msg.type == aiohttp.WSMsgType.BINARY and msg.data[:1] == b"\x00":
                return ""

    async def _turn_on(self, ws, text: str, timeout: float) -> dict:
        self.opened.clear(), self.toolcalls.clear(), self.app_tools.clear(), self.lines.clear()
        said, events, t0 = [], [], time.monotonic()
        first_act = None
        await ws.send_str(json.dumps({"type": "say", "text": text}))
        seen_busy = False
        while time.monotonic() - t0 < timeout:
            try:
                msg = await asyncio.wait_for(ws.receive(), 5)
            except asyncio.TimeoutError:
                continue
            if msg.type != aiohttp.WSMsgType.BINARY:
                if msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    break
                continue
            kind, body = msg.data[0], msg.data[1:]
            if kind == 2:
                said.append(body.decode("utf-8", "replace"))
            elif kind == 7:
                state = body.decode()
                if state != "listening":
                    seen_busy = True
                elif seen_busy:
                    break
            elif kind == 9:
                ev = json.loads(body)
                events.append(ev)
                if ev.get("t") == "tool" and first_act is None:
                    first_act = len(" ".join(said).split())
                if ev.get("t") == "confirm":
                    await ws.send_str(json.dumps({"type": "confirm", "answer": "yes"}))
                    seen_busy = False
        await asyncio.sleep(0.5)
        tools = [e.get("name") for e in events if e.get("t") == "tool" and e.get("phase") == "start"]
        return {"request": text, "seconds": round(time.monotonic() - t0, 1), "said": " ".join(said).strip(),
                "tools": tools, "app_tools": list(self.app_tools), "opened": list(self.opened),
                "confirm": any(e.get("t") == "confirm" for e in events),
                "doit": any(e.get("t") == "doit" for e in events),
                "nudged": any("nudge: announced" in c for c in self.toolcalls),
                "words_before_acting": first_act if first_act is not None else len(" ".join(said).split()),
                "toolcall_log": list(self.toolcalls),
                "route": next((l[10:] for l in self.lines if l.startswith("AIR_ROUTE ")), ""),
                "first_audio": next((float(m.group(1)) for l in self.lines
                                     if (m := re.search(r"end-of-speech to first audio ([\d.]+)s", l))), None),
                "latency": next((l[12:] for l in self.lines if l.startswith("AIR_LATENCY ")), "")}

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            self.proc.terminate()
            try:
                await asyncio.wait_for(self.proc.wait(), 15)
            except asyncio.TimeoutError:
                self.proc.kill()


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--llm", default="mlx-community/Qwen3-8B-4bit")
    p.add_argument("--python", default=str(Path.home() / "Library/Application Support/Air/venv-smart/bin/python"))
    p.add_argument("--chat", action="store_true")
    p.add_argument("--think", action="store_true")
    p.add_argument("--only", default="", help="comma list of case numbers (1-based)")
    p.add_argument("--out", default="")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    eng = Engine(a)
    rows = []
    try:
        await eng.start()
        picks = [int(x) for x in a.only.split(",") if x.strip()] or range(1, len(CASES) + 1)
        for i in picks:
            req, tabs, tool = CASES[i - 1]
            r = await eng.turn(req)
            ok_tabs = tabs is None or (len(r["opened"]) == tabs if tabs else True)
            ok_tool = tool is None or tool in r["tools"] or tool in r["app_tools"]
            r["pass"] = bool(ok_tabs and ok_tool and not r["doit"])
            r["first_try"] = r["pass"] and not r["nudged"]
            rows.append(r)
            print(f"[{'PASS' if r['pass'] else 'FAIL'}{'' if r['first_try'] or not r['pass'] else ' after nudge'}] "
                  f"{req[:60]!r}: tabs {len(r['opened'])}/{tabs}, tools {r['tools'] + r['app_tools']}, "
                  f"{r['words_before_acting']} words before acting, {r['seconds']}s | {r['said'][:140]!r}", flush=True)
    finally:
        await eng.stop()
    n = len(rows) or 1
    summary = {"llm": a.llm, "chat": a.chat, "think": a.think,
               "pass": sum(r["pass"] for r in rows), "first_try": sum(r["first_try"] for r in rows), "n": len(rows),
               "avg_words_before_acting": round(sum(r["words_before_acting"] for r in rows) / n, 1)}
    print(json.dumps(summary))
    if a.out:
        Path(a.out).write_text(json.dumps({"summary": summary, "rows": rows}, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
