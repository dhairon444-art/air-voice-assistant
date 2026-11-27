"""Assistant mode: turn what the owner says into filed items.

One short extraction step on the talker splits a brain dump into items (task, event, idea, note, person)
with a destination and a life area for each. The app shows the plan as one card and nothing is filed
until the owner says OK. Corrections become rules ("invoices -> Freelance") kept in the assistant's memory.
Everything filed is logged in the vault's 'Assistant log.md' with where it went.
"""
from __future__ import annotations

import json
import re
import time
from datetime import datetime
from pathlib import Path

KINDS = ("task", "event", "idea", "note", "person")
DEFAULT_LISTS = ["Freelance", "Job Search", "Personal", "Subscriptions", "Shopping"]
AREAS = ("Work", "Family", "Friends", "Health", "Finance", "Personal", "Learning")
IDEAS_FOLDER = "Ideas"

ASSISTANT_PERSONA = (
    "You are Aria in Assistant mode: the owner's personal assistant. Your job is to capture what they tell "
    "you, break it into tasks, events, ideas, notes and people, and file each in the right place after they "
    "confirm; to answer questions about their day (reminders, calendar); and to ask a short clarifying "
    "question when something is vague (a missing date, an unclear list). Be brief, warm and practical; no "
    "opinions or tangents. Never claim something was filed unless the filing step reported it.")

EXTRACT = """You file things for the user. Today is {today}; tomorrow is {tomorrow}. The next days are: {week}.
Split what they said into separate items.
For each item give:
kind: task | event | idea | note | person
text: the item in a few words, in the user's own terms, without the date or time words
destination: task -> one of these Reminders lists: {lists}; event -> "Calendar"; idea -> "Notes"; note -> one of these vault folders: {folders}; person -> "People"
area: one of Work, Family, Friends, Health, Finance, Personal, Learning
when: for a task with a due date or an event, the date and time as YYYY-MM-DDTHH:MM (work it out from today; use 09:00 if only a day was said); else ""
priority: "high" only if they said it's urgent or important, else ""
detail: anything else worth keeping (who, where, why), short, else ""
Rules the user taught you (follow them): {rules}
Answer with JSON only: {{"items": [{{"kind": "...", "text": "...", "destination": "...", "area": "...", "when": "", "priority": "", "detail": ""}}]}}
If nothing should be filed (small talk, or a question for you), answer {{"items": []}}.

What they said: {said}"""

# Requests that are questions or commands for the assistant, not things to file.
_QUESTION = re.compile(r"^\W*(what|what's|whats|when|where|who|how|is|are|do|does|did|can you|could you|should|"
                       r"show|read|tell me|list|any|have i|am i)\b", re.I)
_AREA_WORDS = {
    "Work": r"client|invoice|meeting|project|deadline|boss|work|office|freelance|proposal|report|job|interview|resume|cv|linkedin",
    "Family": r"mum|mom|dad|sister|brother|family|kids?|son|daughter|wife|husband|partner|grandma|grandpa|aunt|uncle|cousin",
    "Friends": r"friend|mate|party|birthday|catch up|drinks|dinner with",
    "Health": r"doctor|dentist|gym|run|workout|physio|medicine|pharmacy|health|sleep|therapy|appointment",
    "Finance": r"bill|pay|bank|tax|rent|budget|subscription|insurance|super|loan|invoice|refund",
    "Learning": r"course|study|learn|read|book|lecture|class|tutorial|exam|assignment|thesis",
}


def area_for(text: str, given: str = "") -> str:
    """The model's area if it's valid, else a keyword guess, else Personal."""
    g = (given or "").strip().title()
    if g in AREAS:
        return g
    low = text.lower()
    for area, words in _AREA_WORDS.items():
        if re.search(rf"\b({words})\b", low):
            return area
    return "Personal"


def looks_like_question(text: str) -> bool:
    return bool(_QUESTION.search(text or "")) or (text or "").strip().endswith("?")


class AssistantMemory:
    """Filing rules learned from corrections, in Air's support folder (not the vault)."""

    def __init__(self, path: Path):
        self.path = path
        try:
            self.data = json.loads(path.read_text())
        except Exception:
            self.data = {"rules": [], "checkins": {}}

    @property
    def rules(self) -> list[str]:
        return self.data.get("rules", [])[-40:]

    def learn(self, item_text: str, kind: str, destination: str) -> str:
        rule = f"'{item_text}' ({kind}) goes to {destination}"
        rules = self.data.setdefault("rules", [])
        if rule not in rules:
            rules.append(rule)
            self.save()
        return rule

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=1))


def _json_obj(text: str) -> dict:
    text = re.sub(r"<think>.*?</think>|<\|channel>.*?<channel\|>", "", text or "", flags=re.S)
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return {}
    try:
        return json.loads(m.group(0))
    except ValueError:
        return {}


def _iso(when: str) -> str:
    when = (when or "").strip()
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            d = datetime.strptime(when[:16] if "T" in when or " " in when else when[:10], fmt)
            return d.strftime("%Y-%m-%dT%H:%M") if fmt != "%Y-%m-%d" else d.strftime("%Y-%m-%dT09:00")
        except ValueError:
            continue
    return ""


_DAYS = r"(monday|tuesday|wednesday|thursday|friday|saturday|sunday|today|tonight|tomorrow|next week|this week|the weekend)"
_DATE_WORDS = re.compile(rf"\s*(,?\s*\b(by|on|at|this|next|before|for)\s+)?\b{_DAYS}\b(\s+(morning|afternoon|evening|night))?"
                         r"(\s*(at\s*)?\d{1,2}(:\d{2})?\s*(am|pm)?)?|\s*\bat\s+\d{1,2}(:\d{2})?\s*(am|pm)\b", re.I)


def clean_title(text: str) -> str:
    """'Dentist on Tuesday at 3pm' -> 'Dentist' (the date is kept separately)."""
    t = _DATE_WORDS.sub("", text).strip(" ,.-")
    return (t[:1].upper() + t[1:]) if t else text


def _future(when: str) -> str:
    """A date the model put in the past ('Tuesday' read as last Tuesday) moves forward by weeks;
    today stays today."""
    if not when:
        return ""
    from datetime import timedelta
    d = datetime.strptime(when, "%Y-%m-%dT%H:%M")
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    while d < today:
        d += timedelta(days=7)
    return d.strftime("%Y-%m-%dT%H:%M")


_URGENT = re.compile(r"\b(urgent|urgently|important|asap|as soon as possible|priority|critical|top of the list)\b", re.I)


def _relative_day(it: dict, when: str, said: str) -> str:
    """'tomorrow' / 'today' / 'tonight' next to this item in what was said: trust the words, not the model."""
    if not when:
        return when
    from datetime import timedelta
    words = " ".join(str(it.get(k, "")) for k in ("text", "detail", "when"))
    key = str(it.get("text", "")).split()[:3]
    near = ""
    if key and said:
        i = said.lower().find(" ".join(key).lower())
        near = said[i:i + 120] if i >= 0 else ""
    blob = (words + " " + near).lower()
    base = datetime.now()
    if "tomorrow" in blob:
        day = base + timedelta(days=1)
    elif re.search(r"\b(today|tonight|this (morning|afternoon|evening))\b", blob):
        day = base
    else:
        return when
    return day.strftime("%Y-%m-%d") + when[10:]


def normalise(raw: dict, lists: list[str], folders: list[str], said: str = "") -> list[dict]:
    """Clean the model's items: known kinds, valid destinations, ISO dates, no empties or duplicates."""
    out, seen = [], set()
    for it in (raw.get("items") or [])[:12]:
        if not isinstance(it, dict):
            continue
        kind = str(it.get("kind", "")).strip().lower()
        text = str(it.get("text", "")).strip()
        if kind not in KINDS or not text or text.lower() in seen:
            continue
        seen.add(text.lower())
        dest = str(it.get("destination", "")).strip()
        when = _future(_relative_day(it, _iso(str(it.get("when", "") or it.get("due", ""))), said))
        if kind == "task":
            dest = next((l for l in lists if l.lower() == dest.lower()), None) or \
                next((l for l in lists if dest and dest.lower() in l.lower()), "Personal" if "Personal" in lists else lists[0])
        elif kind == "event":
            dest = "Calendar"
            if not when:
                kind, dest = "task", "Personal" if "Personal" in lists else lists[0]   # no date: keep it as a to-do
        elif kind == "idea":
            dest = "Notes"
        elif kind == "person":
            dest = "People"
        elif kind == "note":
            dest = next((f for f in folders if f.lower() == dest.lower()), folders[0] if folders else "Inbox")
        if when:
            text = clean_title(text)
        out.append({"id": len(out) + 1, "kind": kind, "text": text[:160], "destination": dest,
                    "area": area_for(text + " " + str(it.get("detail", "")), str(it.get("area", ""))),
                    "when": when, "priority": "high" if str(it.get("priority", "")).lower() == "high"
                    and (not said or _URGENT.search(said)) else "",
                    "detail": str(it.get("detail", "")).strip()[:300]})
    return out


def extract(generate, said: str, lists: list[str] | None = None, folders: list[str] | None = None,
            rules: list[str] | None = None) -> list[dict]:
    """generate(messages, max_tokens) -> str (the loaded talker)."""
    lists = lists or DEFAULT_LISTS
    folders = folders or ["Inbox"]
    from datetime import timedelta
    now = datetime.now()
    week = ", ".join(f"{(now + timedelta(days=i)).strftime('%A')} = {(now + timedelta(days=i)).strftime('%Y-%m-%d')}" for i in range(1, 8))
    prompt = EXTRACT.format(today=now.strftime("%A %Y-%m-%d %H:%M"), tomorrow=(now + timedelta(days=1)).strftime("%A %Y-%m-%d"), week=week, lists=", ".join(lists),
                            folders=", ".join(folders[:30]), rules="; ".join(rules or []) or "none yet", said=said[:3000])
    return normalise(_json_obj(generate([{"role": "user", "content": prompt}], 700)), lists, folders, said=said)


_NOUN = {"task": "reminder", "event": "event", "idea": "idea", "note": "note", "person": "person"}


def plan_summary(items: list[dict]) -> str:
    """'3 items: 2 reminders in Job Search, 1 idea in Notes.'"""
    if not items:
        return ""
    groups: dict[tuple, int] = {}
    for it in items:
        key = (_NOUN[it["kind"]], it["destination"])
        groups[key] = groups.get(key, 0) + 1
    parts = []
    for (noun, dest), n in groups.items():
        plural = noun + ("s" if n > 1 else "") if noun != "person" else ("people" if n > 1 else "person")
        parts.append(f"{n} {plural} in {dest}")
    return f"{len(items)} item{'s' if len(items) > 1 else ''}: " + ", ".join(parts) + "."


def tool_call(it: dict) -> tuple[str, dict]:
    """The app tool (and arguments) that files one item."""
    k = it["kind"]
    tags = ["air", it["area"].lower()]
    if k == "task":
        a = {"title": it["text"], "list": it["destination"]}
        if it.get("when"):
            a["due"] = it["when"]
        if it.get("priority"):
            a["priority"] = "high"
        if it.get("detail"):
            a["notes"] = it["detail"]
        return "add_reminder", a
    if k == "event":
        return "create_event", {"title": it["text"], "start": it["when"], **({"notes": it["detail"]} if it.get("detail") else {})}
    if k == "idea":
        return "apple_note", {"folder": IDEAS_FOLDER, "title": it["text"], "body": it.get("detail") or it["text"], "tags": tags}
    if k == "person":
        return "vault_note", {"folder": "", "title": "People", "content": f"{it['text']}" + (f": {it['detail']}" if it.get("detail") else ""),
                              "append": True}
    return "vault_note", {"folder": it["destination"], "title": it["text"], "content": it.get("detail") or it["text"],
                          "append": False, "tags": tags}


def corrections(before: list[dict], after: list[dict]) -> list[tuple[str, str, str]]:
    """Items whose destination or kind the owner changed: (text, kind, destination) to learn."""
    old = {it["id"]: it for it in before}
    out = []
    for it in after:
        o = old.get(it.get("id"))
        if o and (o["destination"] != it.get("destination") or o["kind"] != it.get("kind")):
            out.append((it["text"], it["kind"], it["destination"]))
    return out


def log_filed(vault: Path, results: list[tuple[dict, dict]], session_note: Path | None) -> Path:
    """Append what was filed where to 'Assistant log.md' (newest at the bottom)."""
    log = vault / "Assistant log.md"
    if not log.exists():
        log.write_text("---\ntags: [air, assistant]\n---\n# Assistant log\n\nWhat Aria filed, and where.\n\n"
                       "| When | Item | Kind | Area | Filed in | Result |\n| --- | --- | --- | --- | --- | --- |\n")
    link = f"[[{session_note.stem}]]" if session_note else ""
    rows = []
    for it, res in results:
        status = "done" if res.get("ok") else ("not filed: " + str(res.get("error", ""))[:80])
        text = it["text"].replace("|", "/")
        rows.append(f"| {time.strftime('%Y-%m-%d %H:%M')} | {text} | {it['kind']} | {it['area']} | "
                    f"{it['destination']}{' ' + it['when'] if it.get('when') else ''} | {status} {link} |")
    with log.open("a") as f:
        f.write("\n".join(rows) + "\n")
    return log


def vault_folders(vault: Path) -> list[str]:
    """Top-level vault folders a note could go to (not Air's own)."""
    skip = {"Sessions", "Assistant", ".obsidian", ".trash", "Templates"}
    try:
        return sorted(p.name for p in vault.iterdir() if p.is_dir() and p.name not in skip and not p.name.startswith(".")) or ["Notes"]
    except OSError:
        return ["Notes"]


# ---------------- check-ins ----------------
_CHECKIN = re.compile(r"\b(morning brief|brief|wrap[- ]?up|evening (check[- ]?in|summary))\b.*?\b(at|to)\s+"
                      r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?", re.I)


def parse_checkin(text: str) -> tuple[str, str] | None:
    """'move my morning brief to 8' -> ('brief', '08:00'); 'wrap-up at 7:30 pm' -> ('wrapup', '19:30')."""
    m = _CHECKIN.search(text or "")
    if not m:
        return None
    kind = "wrapup" if re.search(r"wrap|evening", m.group(1), re.I) else "brief"
    h, mi, ap = int(m.group(4)), int(m.group(5) or 0), (m.group(6) or "").lower()
    if ap == "pm" and h < 12:
        h += 12
    if ap == "am" and h == 12:
        h = 0
    if not ap and kind == "wrapup" and h < 12:
        h += 12   # "wrap-up at 7" means the evening
    if not (0 <= h < 24 and 0 <= mi < 60):
        return None
    return kind, f"{h:02d}:{mi:02d}"
