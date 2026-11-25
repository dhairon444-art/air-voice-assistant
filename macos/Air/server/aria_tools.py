"""Tools Aria can use on this Mac. The Air app (Swift) executes them; this module defines the
schemas the language model sees, which tools need a spoken "yes" first, and the exact sentence
Aria says before running one of those."""

from __future__ import annotations

import re
from datetime import datetime


def _fn(name: str, description: str, props: dict | None = None, required: list | None = None) -> dict:
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": props or {}, "required": required or []}}}


S = {"type": "string"}
N = {"type": "number"}

TOOLS = [
    # apps
    _fn("list_running_apps", "List the apps that are running."),
    _fn("open_app", "Open (launch) an app by name, e.g. Safari, Notes, Calendar.", {"name": S}, ["name"]),
    _fn("switch_to_app", "Bring a running app to the front.", {"name": S}, ["name"]),
    _fn("quit_app", "Quit an app by name.", {"name": S}, ["name"]),
    # calendar
    _fn("calendar_events", "Read calendar events. Defaults to today.",
        {"date": {"type": "string", "description": "YYYY-MM-DD start day"},
         "days": {"type": "integer", "description": "number of days, 7 for a week"}}),
    _fn("create_event", "Create a calendar event (meetings, appointments). For to-dos and 'remind me to...' use add_reminder instead.",
        {"title": S, "start": {"type": "string", "description": "YYYY-MM-DDTHH:MM local time"},
         "duration_minutes": {"type": "integer"}, "calendar": S, "location": S}, ["title", "start"]),
    _fn("move_event", "Move an event (use the id from calendar_events) to a new start time.",
        {"event_id": S, "new_start": {"type": "string", "description": "YYYY-MM-DDTHH:MM"}},
        ["event_id", "new_start"]),
    _fn("delete_event", "Delete a calendar event by id (from calendar_events).", {"event_id": S}, ["event_id"]),
    # reminders
    _fn("reminder_lists", "List the reminder lists."),
    _fn("list_reminders", "Read open (not completed) reminders, optionally from one list.", {"list": S}),
    _fn("add_reminder", "Add a to-do reminder in the Reminders app. Use this for 'remind me to...'.",
        {"title": S, "list": S, "due": {"type": "string", "description": "YYYY-MM-DDTHH:MM, optional"}},
        ["title"]),
    _fn("complete_reminder", "Mark a reminder as done (id from list_reminders).", {"reminder_id": S}, ["reminder_id"]),
    _fn("delete_reminder", "Delete a reminder (id from list_reminders).", {"reminder_id": S}, ["reminder_id"]),
    # Air vault (Obsidian)
    _fn("search_conversations", "Search past Air conversations saved in the Obsidian vault.", {"query": S}, ["query"]),
    _fn("read_conversation", "Read one past conversation by date (YYYY-MM-DD) or note name.", {"which": S}, ["which"]),
    _fn("create_note", "Create a new note in the Air Obsidian vault.", {"title": S, "content": S}, ["title", "content"]),
    _fn("append_to_note", "Append text to a note in the Air Obsidian vault (creates it if missing).",
        {"title": S, "content": S}, ["title", "content"]),
    # files
    _fn("find_files", "Find files or folders by name with Spotlight.", {"query": S}, ["query"]),
    _fn("open_file", "Open a file or folder (path from find_files) in its default app.", {"path": S}, ["path"]),
    _fn("reveal_in_finder", "Show a file or folder in Finder.", {"path": S}, ["path"]),
    # system
    _fn("get_date_time", "Current date and time. Use it whenever the user asks the time."),
    _fn("battery_status", "Battery level and whether it is charging."),
    _fn("get_volume", "Current output volume and mute state."),
    _fn("set_volume", "Set output volume 0 to 100.", {"level": N}, ["level"]),
    _fn("set_mute", "Mute or unmute the sound output.", {"muted": {"type": "boolean"}}, ["muted"]),
    # music
    _fn("music_now_playing", "What is playing in the Music app."),
    _fn("music_control", "Control the Music app.",
        {"action": {"type": "string", "enum": ["play", "pause", "next", "previous"]}}, ["action"]),
    # shortcuts
    _fn("list_shortcuts", "List the user's Apple Shortcuts."),
    _fn("run_shortcut", "Run one of the user's Apple Shortcuts by name.", {"name": S, "input": S}, ["name"]),
    # mail / messages
    _fn("mail_unread", "Unread email count and the senders and subjects of the latest unread emails."),
    _fn("messages_unread", "Unread iMessage count and senders."),
    _fn("send_email", "Send an email with the Mail app.", {"to": S, "subject": S, "body": S}, ["to", "subject", "body"]),
    _fn("send_message", "Send an iMessage or SMS with the Messages app.",
        {"to": {"type": "string", "description": "phone number or email"}, "text": S}, ["to", "text"]),
    # web (only the query or URL leaves the Mac)
    _fn("web_search", "Search the web (DuckDuckGo and Wikipedia) to check a fact or find something. Returns numbered sources.",
        {"query": S}, ["query"]),
    _fn("open_url", "Open a web link in the user's default browser.", {"url": S}, ["url"]),
    _fn("web_search_and_open", "Search the web and open the best result in the browser (e.g. 'open YouTube').",
        {"query": S}, ["query"]),
    _fn("open_source", "Open source number N from the last answer's sources in the browser ('open that source').",
        {"number": {"type": "integer"}}),
    _fn("read_page", "Fetch a web page's readable text to read, summarise or fact-check it.", {"url": S}, ["url"]),
    _fn("extract_page", "Extract a page's text plus tables, lists, prices, dates and links, ready to save.",
        {"url": S}, ["url"]),
    _fn("get_video_transcript", "Get a video's transcript from its captions (YouTube and other sites).",
        {"url": S}, ["url"]),
    _fn("transcribe_video_audio", "Transcribe a video without captions here on the Mac (temporary audio, deleted after).",
        {"url": S}, ["url"]),
    _fn("save_as", "Save the last transcript or extracted page (or given text) as Excel, Word, CSV, or a note in the Air vault. "
        "Files go to Documents/Air Exports and are never overwritten.",
        {"format": {"type": "string", "enum": ["xlsx", "docx", "csv", "md"]}, "title": S,
         "content": {"type": "string", "description": "optional text to save instead of the last extraction"}},
        ["format"]),
]
TOOLS += [
    _fn("look_at_screen", "Look at the user's screen (or just the front window) and answer a question about it. "
        "Only when the user asks you to look.",
        {"question": S, "scope": {"type": "string", "enum": ["screen", "window"]},
         "save": {"type": "boolean", "description": "true only if the user asked to save the screenshot"}},
        ["question"]),
    _fn("look_at_image", "Look at an image the user points to: the one they copied (clipboard), the file selected "
        "in Finder, or a file path, and answer a question about it.",
        {"question": S, "source": {"type": "string", "enum": ["clipboard", "finder", "file"]}, "path": S},
        ["question", "source"]),
]
VISION_TOOLS = {"look_at_screen", "look_at_image"}
TOOL_NAMES = {t["function"]["name"] for t in TOOLS}

WEB_TOOLS = {"web_search", "open_url", "web_search_and_open", "open_source", "read_page", "extract_page",
             "get_video_transcript", "transcribe_video_audio", "save_as"}

TOOL_NAMES = {t["function"]["name"] for t in TOOLS}

# Anything that changes, sends or deletes needs a spoken "yes" first. Opening, switching and
# revealing (navigation) and playback controls run directly.
NEEDS_CONFIRMATION = {
    "quit_app", "create_event", "move_event", "delete_event", "add_reminder", "complete_reminder",
    "delete_reminder", "create_note", "append_to_note", "set_volume", "set_mute", "run_shortcut",
    "send_email", "send_message", "transcribe_video_audio",
}

ON_HOLD = {
    "look_at_screen": "Looking at your screen.",
    "look_at_image": "Let me look at that image.",
    "web_search": "Let me check that.",
    "read_page": "Let me read it.",
    "extract_page": "Let me pull that out.",
    "get_video_transcript": "Let me get the transcript.",
    "web_search_and_open": "Let me find it.",
    "calendar_events": "Let me check your calendar.",
    "list_reminders": "Let me look at your reminders.",
    "reminder_lists": "Let me look at your reminders.",
    "search_conversations": "Let me look through our past conversations.",
    "read_conversation": "Let me find that conversation.",
    "find_files": "Let me search for that.",
    "mail_unread": "Let me check your mail.",
    "messages_unread": "Let me check your messages.",
    "list_shortcuts": "Let me see your shortcuts.",
}

TOOL_GUIDE = (
    "You can act on the user's Mac with the provided tools: apps, calendar, reminders, the Air "
    "notes vault, files, volume, music, Apple Shortcuts, mail and messages. Use a tool whenever "
    "the user asks for something a tool can do; never pretend you did something without a tool. "
    "For actions that change, send or delete something, call the tool directly: the app will read "
    "the exact action back to the user and only run it after they say yes, so do not ask for "
    "permission yourself first. After a tool runs, tell the user the result briefly and naturally. "
    "Resolve relative dates like tomorrow or next Friday yourself, using the current date and time "
    "given below; call get_date_time when you need the current time. "
    "Vision: you can look at the user's screen or an image with look_at_screen or look_at_image, "
    "but only when they ask you to look; never on your own. "
    "Web: you can search, open, read and extract public pages and video transcripts, and save results as "
    "Excel, Word, CSV or a note in the vault. You cannot click, fill in forms, log in, buy, post or "
    "download files; say so if asked. When you use web results, say briefly what the answer is based on. "
    "Never guess or make up a URL: to open something you found, use open_source with its number, or "
    "web_search_and_open; use open_url only for a link the user gave or a tool returned. "
    "Rules: 1) If the user asks you to do something on the Mac, your reply must contain the matching "
    "tool call; an action only happens through a tool call, so never say you did something unless a "
    "tool result in this conversation says so. 2) Never state the current time or date from memory; "
    "call get_date_time. 3) If you need information first (like the id of an event or which apps "
    "are running), call that tool, then call the action tool next."
)


def _when(s: str | None) -> str:
    if not s:
        return ""
    try:
        d = datetime.fromisoformat(s)
        return d.strftime("%A %-d %B at %-I:%M %p").replace(":00 ", " ")
    except ValueError:
        return s


def describe(name: str, a: dict) -> str:
    """The exact sentence Aria says before a confirmation-required tool runs."""
    a = {k: (v.strip().rstrip(".!?;,") if isinstance(v, str) else v) for k, v in a.items()}
    q = " Should I go ahead? Please say yes or no."
    if name == "quit_app":
        return f"I'm about to quit {a.get('name')}. Any unsaved work there could be lost.{q}"
    if name == "create_event":
        dur = a.get("duration_minutes") or 60
        cal = f" in your {a['calendar']} calendar" if a.get("calendar") else ""
        loc = f" at {a['location']}" if a.get("location") else ""
        return f"I'm about to add an event called {a.get('title')}{loc}, on {_when(a.get('start'))} for {dur} minutes{cal}.{q}"
    if name == "move_event":
        return f"I'm about to move the event {a.get('_label') or a.get('event_id')} to {_when(a.get('new_start'))}.{q}"
    if name == "delete_event":
        return f"I'm about to delete the event {a.get('_label') or a.get('event_id')} from your calendar.{q}"
    if name == "add_reminder":
        due = f", due {_when(a.get('due'))}" if a.get("due") else ""
        lst = f" to your {a['list']} list" if a.get("list") else ""
        return f"I'm about to add a reminder{lst}: {a.get('title')}{due}.{q}"
    if name == "complete_reminder":
        return f"I'm about to mark the reminder {a.get('_label') or a.get('reminder_id')} as done.{q}"
    if name == "delete_reminder":
        return f"I'm about to delete the reminder {a.get('_label') or a.get('reminder_id')}.{q}"
    if name == "create_note":
        return f"I'm about to create a note called {a.get('title')} in your Air vault, saying: {a.get('content')}.{q}"
    if name == "append_to_note":
        return f"I'm about to add this to your note {a.get('title')}: {a.get('content')}.{q}"
    if name == "set_volume":
        return f"I'm about to set the volume to {int(float(a.get('level', 0)))} percent.{q}"
    if name == "set_mute":
        return f"I'm about to {'mute' if a.get('muted') else 'unmute'} the sound.{q}"
    if name == "run_shortcut":
        extra = f" with the input {a['input']}" if a.get("input") else ""
        return f"I'm about to run your shortcut called {a.get('name')}{extra}.{q}"
    if name == "send_email":
        return (f"I'm about to send an email to {a.get('to')}, with the subject {a.get('subject')}, "
                f"saying: {a.get('body')}.{q}")
    if name == "transcribe_video_audio":
        return (f"I'm about to download this video's audio temporarily and transcribe it here on the Mac; "
                f"the audio is deleted afterwards.{q}")
    if name == "send_message":
        return f"I'm about to send a message to {a.get('to')} saying: {a.get('text')}.{q}"
    return f"I'm about to run {name.replace('_', ' ')}.{q}"


def parse_tool_calls(text: str) -> list[dict]:
    """Find tool calls in Qwen form (<tool_call>{json}</tool_call>) or Gemma 4 form
    (<|tool_call>call:name{key:<|"|>value<|"|>}<tool_call|>)."""
    import json

    if "<|tool_call>" in text or "call:" in text:
        try:
            from mlx_lm.tool_parsers import gemma4

            # Tolerate common slips: call:name(...) instead of call:name{...}, doubled string delimiters.
            fixed = re.sub(r"call:([\w-]+)\((.*?)\)(?=\s*(<tool_call\|>|$))", r"call:\1{\2}", text, flags=re.S)
            fixed = fixed.replace('<|"|><|"|>', '<|"|>')
            fixed = re.sub(r",\s+(\w+):", r",\1:", fixed)
            r = gemma4.parse_tool_call(fixed)
            r = r if isinstance(r, list) else [r]
            return [{"name": c["name"], "arguments": c.get("arguments") or {}} for c in r]
        except Exception:
            pass
    calls = []
    dec = json.JSONDecoder()
    if "<tool_call>" not in text:
        loose = parse_loose_calls(text)
        if loose:
            return loose
    for m in re.finditer(r"<tool_call>", text):
        start = text.find("{", m.end())
        if start < 0:
            continue
        try:
            obj, _ = dec.raw_decode(text[start:])
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("name"):
            args = obj.get("arguments") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {}
            calls.append({"name": obj["name"], "arguments": args})
    return calls


ACTION_TOOLS = NEEDS_CONFIRMATION | {"open_app", "switch_to_app", "open_file", "reveal_in_finder", "music_control",
                                     "open_url", "web_search_and_open", "open_source", "save_as"}

_INTENT = re.compile(r"\b(let me (?!know)|i'll|i will|i'm going to|just a moment|one moment|give me a (moment|second)|"
                     r"right away|done|has been|have been|i've (closed|quit|moved|deleted|cancel+ed|added|set|muted|sent|created|marked))\b",
                     re.I)


_TOOL_RE = None


def _tool_regex():
    global _TOOL_RE
    if _TOOL_RE is None:
        names = sorted(TOOL_NAMES, key=len, reverse=True)
        alts = "|".join(re.escape(n) + "|" + re.escape(n.replace("_", "")) for n in names)
        _TOOL_RE = re.compile(rf"\b({alts})\b\s*(\(([^()]*)\)|((?:\s*\w+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s,)]+),?)+))")
    return _TOOL_RE


def parse_loose_calls(text: str) -> list[dict]:
    """Small models sometimes write a call as code or plain text instead of <tool_call> JSON,
    e.g. add_reminder(title="Call Mum", due="...") or 'addreminder title="Call Mum"'.
    Recognise those for known tools so the call still goes through the normal path."""
    out = []
    by_flat = {n.replace("_", ""): n for n in TOOL_NAMES}
    for m in _tool_regex().finditer(text):
        name = m.group(1)
        name = name if name in TOOL_NAMES else by_flat.get(name)
        argstr = m.group(3) if m.group(3) is not None else (m.group(4) or "")
        args = {}
        for k, v in re.findall(r"(\w+)\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s,)]+)", argstr):
            v = v.strip("\"'")
            if v.lower() in ("true", "false"):
                v = v.lower() == "true"
            else:
                try:
                    v = int(v) if re.fullmatch(r"-?\d+", v) else float(v) if re.fullmatch(r"-?\d+\.\d+", v) else v
                except ValueError:
                    pass
            args[k] = v
        if name and (args or m.group(2).startswith("(")):
            out.append({"name": name, "arguments": args})
    return out


def looks_like_tool_text(text: str) -> bool:
    """A sentence that is really a tool call written as text (never speak it)."""
    return bool(_tool_regex().search(text or ""))


_ACT = (r"(closed|quit|moved|deleted|cancel+ed|added|set|muted|unmuted|sent|created|marked|opened|switched|"
        r"paused|played|ran|turned|saved|exported|written|wrote|downloaded|scheduled|completed)")
_CLAIM = re.compile(
    rf"\b(i'?ve|i have|i just|i went ahead and)\b[^.!?]{{0,60}}?\b{_ACT}\b"
    rf"|\bi (just |also )?{_ACT} (it|the|your|a|that|them)\b"
    rf"|\b(is|are) now (open|closed|muted|unmuted|playing|paused|saved|set to)\b"
    rf"|\b(has|have) been (successfully )?(opened|closed|quit|muted|added|deleted|moved|created|sent|saved|exported|scheduled)\b"
    r"|\ball (done|set)\b", re.I)


def claims_action(text: str) -> bool:
    """The reply says something was done (past tense)."""
    return bool(_CLAIM.search(text or ""))


HONEST = "Sorry, I haven't actually done that. Could you ask me again?"


def announces_action(text: str) -> bool:
    """The reply talks about doing something but contains no tool call (a likely hallucination)."""
    return bool(_INTENT.search(text or ""))


NUDGE = ("(System note for the assistant, not from the user: you described an action but did not call "
         "a tool, so nothing happened. Call the right tool now, or say plainly that you could not do it.)")


_YES = re.compile(r"^\W*(yes|yeah|yep|yup|sure|ok(ay)?|go ahead|do it|please do|confirm(ed)?|correct|"
                  r"that'?s right|absolutely|definitely|of course)\b", re.I)
_NO = re.compile(r"\b(no|nope|don'?t|do not|stop|cancel|never ?mind|wait|not now|hold on)\b", re.I)


def classify_reply(text: str) -> str:
    """'yes' only for a clear yes; 'no' for a refusal; otherwise 'unclear' (treated as not confirmed)."""
    t = text.strip()
    if _NO.search(t):
        return "no"
    if _YES.search(t):
        return "yes"
    return "unclear"
