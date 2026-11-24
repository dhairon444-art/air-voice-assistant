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
        mode = fm.get("mode", "Myra")
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

    `mode` is the user-facing mode name (e.g. "Myra" or "Smart"); `assistant` is the
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
