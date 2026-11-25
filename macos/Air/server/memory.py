"""Aria's long-term memory, kept as plain Markdown in the Air Obsidian vault.

* Profile.md: what Aria knows about the owner (goals, preferences, decisions, corrections,
  open threads). Aria adds to it after each session; the owner can edit it in Obsidian at any
  time. Aria never deletes lines, so the owner's edits always survive. Lines the owner deletes
  are gone for good, and Aria won't re-add the same fact unless it comes up again.
* Each session note gets a `summary:` in its frontmatter and a summary callout at the top.
* Retrieval: BM25 over session summaries. The corpus is small (one short summary per session)
  and matching is mostly on topic words, so BM25 is fast (<5 ms), needs no extra model, and
  uses no extra RAM.
"""

from __future__ import annotations

import json
import math
import re
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

from air_common import read_frontmatter

SECTIONS = [
    ("about", "About me"),
    ("goals", "Goals"),
    ("preferences", "Preferences"),
    ("decisions", "Decisions"),
    ("corrections", "Corrections"),
    ("open_threads", "Open threads"),
]
TITLE_TO_KEY = {t.lower(): k for k, t in SECTIONS}

PROFILE_TEMPLATE = """---
tags: [air, profile]
---
# Profile

> [!info] What Aria remembers about you
> Aria reads this note at the start of every conversation and adds to it afterwards.
> Edit it freely: change or delete any line, or add your own. Aria never deletes lines here,
> so your edits stay. Lines Aria adds end with the date they were learned.

"""


def profile_path(vault: Path) -> Path:
    return vault / "Profile.md"


def ensure_profile(vault: Path) -> Path:
    p = profile_path(vault)
    if not p.exists():
        body = PROFILE_TEMPLATE + "\n".join(f"## {title}\n" for _, title in SECTIONS)
        p.write_text(body, encoding="utf-8")
    return p


def read_profile(vault: Path) -> dict[str, list[str]]:
    """Section key -> bullet texts (without '- '). Unknown sections are kept under their title."""
    p = ensure_profile(vault)
    out: dict[str, list[str]] = {k: [] for k, _ in SECTIONS}
    cur = None
    for line in p.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^##\s+(.*)$", line)
        if m:
            cur = TITLE_TO_KEY.get(m.group(1).strip().lower(), m.group(1).strip())
            out.setdefault(cur, [])
            continue
        if cur and re.match(r"^\s*[-*]\s+\S", line):
            out[cur].append(re.sub(r"^\s*[-*]\s+", "", line).strip())
    return out


def _norm(s: str) -> str:
    s = re.sub(r"\(\d{4}-\d{2}-\d{2}\)$", "", s.strip())
    return re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()


def _similar(a: str, b: str) -> bool:
    na, nb = set(_norm(a).split()), set(_norm(b).split())
    if not na or not nb:
        return False
    return len(na & nb) / min(len(na), len(nb)) >= 0.8


def merge_profile(vault: Path, updates: dict, resolved: list[str]) -> int:
    """Append new facts under their sections (skipping near-duplicates) and mark resolved
    open threads. Never deletes or rewrites existing lines. Returns how many lines changed."""
    p = ensure_profile(vault)
    lines = p.read_text(encoding="utf-8").splitlines()
    existing = read_profile(vault)
    today = datetime.now().strftime("%Y-%m-%d")
    changed = 0

    def section_end(title: str) -> int:
        start = None
        for i, line in enumerate(lines):
            if re.match(rf"^##\s+{re.escape(title)}\s*$", line, re.I):
                start = i
                continue
            if start is not None and line.startswith("## "):
                return i
        if start is None:
            lines.extend(["", f"## {title}"])
            return len(lines)
        return len(lines)

    for key, title in SECTIONS:
        for fact in updates.get(key) or []:
            fact = str(fact).strip().rstrip(".")
            if not fact or len(fact) > 240:
                continue
            if any(_similar(fact, e) for e in existing.get(key, [])):
                continue
            end = section_end(title)
            while end > 0 and not lines[end - 1].strip():
                end -= 1
            lines.insert(end, f"- {fact} ({today})")
            existing.setdefault(key, []).append(fact)
            changed += 1

    for r in resolved or []:
        for i, line in enumerate(lines):
            if line.lstrip().startswith("- ") and _similar(line[2:], str(r)) and "resolved" not in line:
                lines[i] = line.rstrip() + f" · resolved {today}"
                changed += 1
                break
    if changed:
        text = "\n".join(lines).rstrip() + "\n"
        tmp = p.with_name(".Profile.md.tmp")
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(p)
    return changed


def profile_block(vault: Path, max_per_section: int = 8, max_chars: int = 2200) -> str:
    """Compact profile text for the system prompt (newest lines first within each section)."""
    prof = read_profile(vault)
    parts = []
    for key, title in SECTIONS:
        items = [x for x in prof.get(key, []) if "resolved" not in x]
        if items:
            parts.append(f"{title}: " + "; ".join(items[-max_per_section:]))
    for key, items in prof.items():  # owner-added sections
        if key not in dict(SECTIONS) and items:
            parts.append(f"{key}: " + "; ".join(items[-max_per_section:]))
    text = "\n".join(parts)
    return text[:max_chars]


# ------------------------------------------------------------------ sessions ---

def session_summaries(vault: Path) -> list[dict]:
    out = []
    for p in sorted((vault / "Sessions").rglob("*.md"), key=lambda x: x.name, reverse=True):
        fm = read_frontmatter(p)
        s = fm.get("summary", "").strip()
        if s:
            out.append({"path": p, "name": p.stem, "date": fm.get("date", p.stem[:10]), "summary": s})
    return out


_WORD = re.compile(r"[a-z0-9]+")
_STOP = set("""a an the and or but if then so of to in on at for with from by as is are was were be been it its
this that these those i you he she we they me my your our their us them do did does not no yes can could would
should will just about into over under than too very what which who whom when where why how all any some""".split())


def _tokens(s: str) -> list[str]:
    out = []
    for w in _WORD.findall(s.lower()):
        if w in _STOP or len(w) < 2:
            continue
        for suf in ("ing", "ed", "es", "s"):  # light stemming
            if len(w) > 4 and w.endswith(suf):
                w = w[: -len(suf)]
                break
        out.append(w)
    return out


class BM25:
    def __init__(self, docs: list[str], k1: float = 1.4, b: float = 0.75):
        self.docs = [_tokens(d) for d in docs]
        self.k1, self.b = k1, b
        self.avg = sum(map(len, self.docs)) / max(1, len(self.docs))
        df = Counter(t for d in self.docs for t in set(d))
        n = len(self.docs)
        self.idf = {t: math.log(1 + (n - c + 0.5) / (c + 0.5)) for t, c in df.items()}
        self.tf = [Counter(d) for d in self.docs]

    def scores(self, query: str) -> list[float]:
        q = _tokens(query)
        out = []
        for d, tf in zip(self.docs, self.tf):
            s = 0.0
            for t in q:
                if t in tf:
                    f = tf[t]
                    s += self.idf[t] * f * (self.k1 + 1) / (f + self.k1 * (1 - self.b + self.b * len(d) / self.avg))
            out.append(s)
        return out


class Memory:
    """Profile + recent summaries for the system prompt; BM25 recall of older ones per turn."""

    def __init__(self, vault: Path, recent: int = 3):
        self.vault = vault
        self.recent_n = recent
        self.reload()

    def reload(self) -> None:
        ensure_profile(self.vault)
        self.all = session_summaries(self.vault)
        self.recent = self.all[: self.recent_n]
        self.older = self.all[self.recent_n:]
        self.index = BM25([s["summary"] for s in self.older]) if self.older else None

    def system_block(self) -> str:
        prof = profile_block(self.vault)
        parts = ["Memory from earlier conversations with this user (from their Obsidian vault). "
                 "Use it naturally when relevant; don't recite it. If something here conflicts with what "
                 "the user says now, trust the user and say what changed. The user edits this profile "
                 "directly, so treat it as authoritative."]
        parts.append("Profile:\n" + (prof or "(nothing yet)"))
        if self.recent:
            parts.append("Recent conversations:\n" + "\n".join(
                f"- {s['date']}: {s['summary']}" for s in self.recent))
        return "\n\n".join(parts)

    def recall(self, query: str, k: int = 2, min_score: float = 1.5) -> list[dict]:
        if not self.index:
            return []
        sc = self.index.scores(query)
        ranked = sorted(zip(sc, self.older), key=lambda x: -x[0])
        return [d for s, d in ranked[:k] if s >= min_score]


# ---------------------------------------------------------- post-session work ---

SUMMARY_PROMPT = """You maintain long-term memory for a voice assistant called Aria.
Read the conversation and return JSON only, no prose, with this shape:
{{"summary": "2-3 sentences: what was discussed, decided or left open",
 "about": [], "goals": [], "preferences": [], "decisions": [], "corrections": [],
 "open_threads": [], "resolved_threads": []}}
Rules:
- Facts must be about the USER's own life, work, goals, preferences and plans, stated or clearly implied by the user. Never record what Aria said, world facts or answers to questions (e.g. facts about places or products) as facts about the user. If the conversation was only questions and answers or one-off tasks, return empty lists.
- "goals": lasting goals the user said they have (e.g. "Run a half marathon under two hours"), not individual requests made in this conversation ("save this table").
- "decisions": choices the user made about their own life or plans, not tasks Aria carried out.
- "corrections": every time the user said Aria was wrong or corrected a fact or a suggestion ("Actually...", "No, ..."), written as the correct fact ("Coach recommends 3 runs a week plus a rest day, not daily runs"); also instructions on how Aria should behave ("Be more direct").
- "open_threads": only things the USER said they still need to do or want to come back to. Never turn Aria's own questions or suggestions into open threads.
- "resolved_threads": items from the existing open threads below that this conversation resolved, copied verbatim.
- Short, specific, one fact per string, written in third person ("Prefers metric units").
- Skip anything already in the existing profile. Use [] when there is nothing new. Do not invent.

Existing profile:
{profile}

Conversation:
{transcript}
"""


def build_summary_prompt(vault: Path, transcript: str) -> str:
    prof = profile_block(vault, max_per_section=30, max_chars=4000) or "(empty)"
    return SUMMARY_PROMPT.format(profile=prof, transcript=transcript[-12000:])


def parse_json_object(text: str) -> dict:
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S)
    start = text.find("{")
    if start < 0:
        return {}
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
        return obj if isinstance(obj, dict) else {}
    except ValueError:
        return {}


def add_summary_to_note(note: Path, summary: str) -> None:
    """summary: in the frontmatter and a callout at the top of the note body."""
    text = note.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return
    fm_lines = [l for l in m.group(1).splitlines() if not l.startswith("summary:")]
    fm_lines.insert(1 if fm_lines else 0, f"summary: {json.dumps(summary, ensure_ascii=False)}")
    body = text[m.end():]
    body = re.sub(r"^> \[!summary\][^\n]*\n(> [^\n]*\n)*\n?", "", body)
    # put the callout right after the H1 title line
    lines = body.split("\n")
    insert_at = 1 if lines and lines[0].startswith("# ") else 0
    callout = ["", "> [!summary] Summary", "> " + summary]
    lines[insert_at:insert_at] = callout
    out = "---\n" + "\n".join(fm_lines) + "\n---\n" + "\n".join(lines)
    tmp = note.with_name("." + note.name + ".tmp")
    tmp.write_text(out, encoding="utf-8")
    tmp.replace(note)


def transcript_of(note: Path) -> str:
    lines = []
    for line in note.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\*\*\[(\d\d:\d\d)\] ([^:]+):\*\* (.*)$", line)
        if m:
            lines.append(f"{m.group(2)}: {m.group(3)}")
    return "\n".join(lines)
