"""Shared pieces for Air's model servers: stdout protocol, parent watching, and
writing conversations to the Air Obsidian vault."""

from __future__ import annotations

import json
import os
import re
import signal
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

GAP_NEW_LINE_S = 3.0
INDEX_NAME = "Air Index"


def emit(kind: str, msg: str = "") -> None:
    print(f"AIR_{kind} {msg}".rstrip(), flush=True)


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


_tool_waiters: dict[str, list] = {}
_tool_lock = threading.Lock()


def call_app_tool(name: str, args: dict, timeout: float = 60.0) -> dict:
    """Ask Air.app to run a tool (EventKit, Apple Events, files...) and wait for the result.

    Request:  stdout line  AIR_TOOL <id> <json {"name":..., "args":...}>
    Response: stdin line   TOOL_RESULT <id> <json>
    """
    import uuid

    call_id = uuid.uuid4().hex[:12]
    done = threading.Event()
    slot: list = [done, None]
    with _tool_lock:
        _tool_waiters[call_id] = slot
    emit("TOOL", f"{call_id} {json.dumps({'name': name, 'args': args})}")
    if not done.wait(timeout):
        with _tool_lock:
            _tool_waiters.pop(call_id, None)
        return {"ok": False, "error": "The app did not answer in time."}
    return slot[1] or {"ok": False, "error": "empty result"}


def watch_parent(parent_pid: int | None) -> None:
    """Exit when the app dies, even on force quit / crash (SIGKILL).
    stdin also carries tool results from the app (see call_app_tool)."""

    def stdin_watch():
        try:
            for raw in sys.stdin.buffer:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("TOOL_RESULT "):
                    continue
                _, call_id, payload = (line.split(" ", 2) + [""])[:3]
                with _tool_lock:
                    slot = _tool_waiters.pop(call_id, None)
                if slot is not None:
                    try:
                        slot[1] = json.loads(payload)
                    except ValueError:
                        slot[1] = {"ok": False, "error": "bad result from app"}
                    slot[0].set()
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

BRIGHT_SNIPPET_NAME = "air-bright-diagrams"
BRIGHT_SNIPPET = """/* Bright Mermaid charts with dark labels (Air vault). */
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
    if not (vault / f"{INDEX_NAME}.md").exists():
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
    modes: dict[str, int] = {}
    total = 0
    for p in sessions:
        fm = read_frontmatter(p)
        rel = p.relative_to(vault).with_suffix("").as_posix()
        try:
            label = datetime.strptime(p.stem[:15], "%Y-%m-%d %H%M").strftime("%a %d %b %Y, %H:%M")
        except ValueError:
            label = p.stem
        mode = fm.get("mode", "Aria")
        modes[mode] = modes.get(mode, 0) + 1
        try:
            total += int(fm.get("duration_seconds", "0"))
        except ValueError:
            pass
        persona = fm.get("persona", "").replace("|", "/").replace("\n", " ")
        if len(persona) > 60:
            persona = persona[:57] + "..."
        rows.append(
            f"| [[{rel}\\|{label}]] | {mode} | {fm.get('duration', '')} | {fm.get('voice', '')} | {persona} |"
        )

    lines = [
        "---",
        "tags: [air, index]",
        "---",
        f"# {INDEX_NAME}",
        "",
        "Every conversation in Air, newest first. Air.app rewrites this note after each session.",
        "",
        f"**{len(sessions)} session{'' if len(sessions) == 1 else 's'}** · **{fmt_duration(total)}** of conversation in total.",
        "",
    ]
    if sessions:
        palette = ["#38BDF8", "#34D399", "#FBBF24", "#A78BFA", "#FB7185", "#F472B6"]
        theme = {"background": "transparent", "pieTitleTextColor": "#132034",
                 "pieSectionTextColor": "#132034", "pieLegendTextColor": "#132034",
                 "pieStrokeColor": "#132034"}
        for i, c in enumerate(palette * 2):
            theme[f"pie{i + 1}"] = c
        lines += [
            "```mermaid",
            "%%{init: " + json.dumps({"theme": "base", "themeVariables": theme}) + "}%%",
            "pie showData title Sessions by mode",
        ]
        for v, n in sorted(modes.items(), key=lambda kv: -kv[1]):
            lines.append(f'    "{v}" : {n}')
        lines += ["```", ""]
    lines += [
        "| Session | Mode | Duration | Voice | Persona |",
        "| --- | --- | --- | --- | --- |",
    ]
    lines += rows or ["| _No sessions yet_ | | | | |"]
    lines.append("")
    tmp = vault / f".{INDEX_NAME}.md.tmp"
    tmp.write_text("\n".join(lines), encoding="utf-8")
    os.replace(tmp, vault / f"{INDEX_NAME}.md")


class SessionRecorder:
    """Collects both sides of a conversation and keeps a Markdown note up to date.

    `mode` is the user-facing mode name (e.g. "Aria"); `assistant` is the
    speaker label used for the model's lines.
    """

    def __init__(self, vault: Path, voice: str, persona: str, *, mode: str, model_id: str,
                 assistant: str, user_side: bool):
        self.vault = vault
        self.voice = voice
        self.persona = persona
        self.mode = mode
        self.model_id = model_id
        self.assistant = assistant
        self.user_side = user_side
        self.start = datetime.now()
        self.start_mono = time.monotonic()
        self.end: datetime | None = None
        self.segments: list[list] = []  # [offset_seconds, speaker, text]
        self.tool_log: list[dict] = []   # every tool call: time, tool, args, confirmation, result
        self.web_log: list[dict] = []    # every URL searched, opened, read or saved
        self.personality = ""
        self.choices: list[tuple] = []   # (question, options, chosen, correct or None)
        self.watched: list[tuple] = []   # (app, window) seen by Live Screen; only these names are kept
        self.research: list[dict] = []   # research briefs (question, sources with quotes)
        self.thinking: list[tuple] = []  # (time, kind, text), only when Show thinking is on
        self.last_mono: dict[str, float] = {}
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

    prior: str | None = None          # resumed conversation: the note as it was
    resumed_at: datetime | None = None

    def resume(self, note: Path) -> list[dict]:
        """Continue an earlier conversation in ITS note (one note per conversation). The note is never
        rewritten: new transcript lines are inserted after the old ones under a 'Continued' marker.
        Returns the earlier turns as chat messages."""
        self.prior = note.read_text(encoding="utf-8")
        self.path = note
        self.resumed_at = datetime.now()
        msgs = []
        for line in self.prior.splitlines():
            m = re.match(r"^\*\*\[\d+:\d\d\] ([^:]+):\*\* (.*)$", line)
            if m:
                msgs.append({"role": "user" if m.group(1) == "You" else "assistant", "content": m.group(2)})
        return msgs

    def add_text(self, piece: str, speaker: str | None = None, new_line: bool = False) -> None:
        speaker = speaker or self.assistant
        now = time.monotonic()
        with self.lock:
            last = self.segments[-1] if self.segments else None
            if (new_line or last is None or last[1] != speaker
                    or now - self.last_mono.get(speaker, 0.0) > GAP_NEW_LINE_S):
                self.segments.append([now - self.start_mono, speaker, piece.lstrip()])
            else:
                last[2] += piece
            self.last_mono[speaker] = now

    def add_segment(self, offset: float, speaker: str, text: str) -> None:
        """Insert a finished segment at a known time (e.g. from post-session transcription)."""
        with self.lock:
            for o, sp, t in self.segments[-6:]:
                if sp == speaker and t.strip() == text.strip() and abs(o - offset) < 3.0:
                    return  # duplicate (e.g. overlapping transcription chunks)
            self.segments.append([max(0.0, offset), speaker, text])

    def has_text(self) -> bool:
        with self.lock:
            return any(seg[2].strip() for seg in self.segments)

    def render(self, final: bool) -> str:
        end = self.end or datetime.now()
        duration = (end - self.start).total_seconds()
        with self.lock:
            segs = sorted(((o, sp, t.strip()) for o, sp, t in self.segments if t.strip()),
                          key=lambda seg: seg[0])
        words = sum(len(t.split()) for _, sp, t in segs if sp == self.assistant)
        user_words = sum(len(t.split()) for _, sp, t in segs if sp != self.assistant)
        title = self.start.strftime("%a %d %b %Y, %H:%M")
        tag = self.mode.lower().replace(" ", "-")
        fm = [
            "---",
            f"date: {self.start.strftime('%Y-%m-%d')}",
            f'start: "{self.start.strftime("%H:%M:%S")}"',
            f'end: "{end.strftime("%H:%M:%S")}"',
            f'duration: "{fmt_duration(duration)}"',
            f"duration_seconds: {int(round(duration))}",
            f"mode: {self.mode}",
            f"model: {self.model_id}",
            f"voice: {self.voice}",
            *([f"personality: {self.personality}"] if self.personality else []),
            f"persona: {json.dumps(self.persona, ensure_ascii=False)}",
            f"status: {'complete' if final else 'in-progress'}",
            f"tags: [air, session, {tag}]",
            "---",
        ]
        if self.user_side:
            stats_head = f"| Started | Ended | Duration | Mode | Voice | Words from {self.assistant} | Words from you |"
            stats_sep = "| --- | --- | --- | --- | --- | --- | --- |"
            stats_row = (f"| {self.start.strftime('%H:%M:%S')} | {end.strftime('%H:%M:%S')} | "
                         f"{fmt_duration(duration)} | {self.mode} | {self.voice} | {words} | {user_words} |")
            note = ["> [!note] Both sides",
                    "> Your lines come from on-device speech recognition (Parakeet), so expect small mistakes."]
        else:
            stats_head = f"| Started | Ended | Duration | Mode | Voice | Words from {self.assistant} |"
            stats_sep = "| --- | --- | --- | --- | --- | --- |"
            stats_row = (f"| {self.start.strftime('%H:%M:%S')} | {end.strftime('%H:%M:%S')} | "
                         f"{fmt_duration(duration)} | {self.mode} | {self.voice} | {words} |")
            note = [f"> [!note] {self.assistant}'s side only",
                    f"> This mode streams the text of what {self.assistant} says. It does not "
                    "transcribe your microphone, so your side of the conversation is not recorded."]
        body = [
            f"# {self.mode} session · {title}",
            "",
            f"Back to [[{INDEX_NAME}]]",
            "",
            stats_head, stats_sep, stats_row,
            "",
            "## Persona",
            "",
            "> " + self.persona.replace("\n", "\n> "),
            "",
            "## Transcript",
            "",
            *note,
            "",
        ]
        if segs:
            for offset, speaker, text in segs:
                mm, ss = divmod(int(offset), 60)
                body.append(f"**[{mm:02d}:{ss:02d}] {speaker}:** {text}")
                body.append("")
        else:
            body.append("_Nothing was said in this session._")
            body.append("")
        if self.tool_log:
            body += ["## Tool calls", "",
                     "| Time | Tool | Arguments | Confirmation | Result |",
                     "| --- | --- | --- | --- | --- |"]
            for t in self.tool_log:
                cell = lambda v: str(v).replace("|", "\\|").replace("\n", " ")[:160]
                body.append(f"| {t['time']} | {t['tool']} | {cell(json.dumps(t['args'], ensure_ascii=False))} "
                            f"| {t['confirm']} | {cell(t['result'])} |")
            body.append("")
        if self.choices:
            quiz = any(c[3] is not None for c in self.choices)
            body += ["## Choices" + (" and quiz" if quiz else ""), "",
                     "| Question | Options | Answer |" + (" Result |" if quiz else ""),
                     "| --- | --- | --- |" + (" --- |" if quiz else "")]
            cell = lambda v: str(v).replace("|", "\\|").replace("\n", " ")
            for q, opts, chosen, ok in self.choices:
                body.append(f"| {cell(q)} | {cell(' / '.join(opts))} | {cell(chosen)} |" +
                            (f" {'✅' if ok else ('❌' if ok is False else '')} |" if quiz else ""))
            if quiz:
                scored = [c for c in self.choices if c[3] is not None]
                body += ["", f"Score: {sum(1 for c in scored if c[3])} / {len(scored)}"]
            body.append("")
        for r in self.research:
            body += [f"## {'Deep research' if r.get('deep') else 'Research'}: {r['question']}", "",
                     f"{len(r['pages'])} sources in {r['seconds']} s via {r['backend']}. "
                     f"Searches: {'; '.join(r['queries'])}", ""]
            if r.get("brief"):
                body += [r["brief"], ""]
            for p in r["pages"]:
                label = p["title"].replace("[", "(").replace("]", ")").replace("|", "-")
                body.append(f"{p['n']}. [{label}]({p['url']}) ({p['domain']})")
                for q in p["quotes"]:
                    body.append(f"    - \"{q}\"")
            body.append("")
        if self.thinking:
            body += ["> [!abstract]- Thinking", "> What Aria heard, reasoned, called and read in this session.", ">"]
            for t_, kind, text in self.thinking:
                body.append(f"> **{t_} {kind}:** " + text.replace("\n", " ").strip())
                body.append(">")
            body.append("")
        if self.watched:
            body += ["## Screen", ""] + [f"- watched: {a}" + (f" - {w}" if w else "") for a, w in self.watched] + [""]
        if self.web_log:
            body += ["## Sources and web activity", "",
                     "Only search words and links left the Mac.", ""]
            for w in self.web_log:
                label = (w.get("title") or "").replace("[", "(").replace("]", ")") or w["url"]
                target = w["url"] if w["url"].startswith("http") else "file://" + w["url"].replace(" ", "%20")
                body.append(f"- {w['time']} {w['action']}: [{label}]({target})")
            body.append("")
        return "\n".join(fm + body)

    def save(self, final: bool = False) -> None:
        text = self.render(final)
        if self.prior is not None:
            new = [l for l in text.splitlines() if re.match(r"^\*\*\[\d+:\d\d\] ", l)]
            if not new:
                return   # nothing new yet: leave the note exactly as it was
            lines = self.prior.splitlines()
            last = max((i for i, l in enumerate(lines) if re.match(r"^\*\*\[\d+:\d\d\] ", l)), default=len(lines) - 1)
            marker = f"*Continued {self.resumed_at:%a %d %b %Y, %H:%M}*"
            text = "\n".join(lines[:last + 1] + ["", marker, ""] + [l + "\n" for l in new] + lines[last + 1:]) + "\n"
        tmp = self.path.with_name("." + self.path.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, self.path)

    def finish(self) -> Path | None:
        if self.finished:
            return None
        self.finished = True
        _active_recorders.discard(self)
        self.end = datetime.now()
        duration = (self.end - self.start).total_seconds()
        if self.prior is not None:
            # A resumed conversation: never delete its note; just add what's new.
            if self.has_text():
                self.save(final=True)
                write_index(self.vault)
                return self.path
            return None
        if not self.has_text() and duration < 5:
            # Nothing worth keeping (e.g. connect + immediate disconnect).
            self.path.unlink(missing_ok=True)
            write_index(self.vault)
            return None
        self.save(final=True)
        write_index(self.vault)
        return self.path
