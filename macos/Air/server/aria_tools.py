"""Tools Aria can use on this Mac. The Air app (Swift) executes them; this module defines the
schemas the language model sees, which tools need a spoken "yes" first, and the exact sentence
Aria says before running one of those."""

from __future__ import annotations

import json
import re
from urllib.parse import urlparse
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
    _fn("find_files", "Find the user's files or folders with Spotlight, by name or by words inside documents "
        "(e.g. 'resume', 'tax return 2025').", {"query": S}, ["query"]),
    _fn("read_file", "Read the text of a local document (PDF, Word, Pages, RTF, text, Markdown, CSV) to answer "
        "questions about it. Use find_files first to get the path.", {"path": S}, ["path"]),
    _fn("read_browser_tabs", "List the tabs open in the user's browsers (Safari, Chrome, Arc, Tabbit, Brave, Edge), "
        "active tab first, with titles and links. Then use read_page on a tab's url to see what's on it."),
    _fn("open_file", "Open a file or folder (path from find_files) in its default app so the user can see it. "
        "This does not let you read it: to answer questions about a document, use read_file.", {"path": S}, ["path"]),
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
    _fn("web_search", "Quick web search to check one fact or find something. Returns numbered sources with their sites.",
        {"query": S}, ["query"]),
    _fn("research", "Research a question across many web pages (takes about 20-30 seconds): use for comparisons, "
        "disputed or surprising claims, recent events, or when the user says research or look into. Set deep to true "
        "only when the user asks for deep or thorough research.",
        {"question": S, "deep": {"type": "boolean"}}, ["question"]),
    _fn("open_url", "Open one or more web links in the user's default browser, each in a new tab, in order. "
        "For several sites use urls (up to 15).", {"url": S, "urls": {"type": "array", "items": S}}),
    _fn("web_search_and_open", "Search the web and open results in the browser. One site: query ('open YouTube'). "
        "Several sites: queries, one per site ('open LinkedIn, Seek and Indeed'). The top N results of one search: "
        "query plus count ('open the top 3 results').",
        {"query": S, "queries": {"type": "array", "items": S}, "count": {"type": "integer"}}),
    _fn("open_source", "Open sources from the last answer in the browser: number N, several numbers, or all true "
        "('open these sources').",
        {"number": {"type": "integer"}, "numbers": {"type": "array", "items": {"type": "integer"}}, "all": {"type": "boolean"}}),
    _fn("read_page", "Fetch the readable text of one or more web pages (url or urls, up to 15) to read, summarise "
        "or fact-check them.", {"url": S, "urls": {"type": "array", "items": S}}),
    _fn("extract_page", "Extract a page's text plus tables, lists, prices, dates and links, ready to save.",
        {"url": S}, ["url"]),
    _fn("get_video_transcript", "Get a video's transcript from its captions (YouTube and other sites).",
        {"url": S}, ["url"]),
    _fn("transcribe_video_audio", "Transcribe a video without captions here on the Mac (temporary audio, deleted after).",
        {"url": S}, ["url"]),
    _fn("run_skill", "Run one of the user's installed skills (for example Summarize, Extract Wisdom, Analyze Claims) on "
        "some text, or on the last page, transcript or research you got. Use when the user names a skill or asks "
        "for that kind of task on content.",
        {"skill": S, "text": {"type": "string", "description": "the text to work on; leave empty to use the last page, transcript or research"}},
        ["skill"]),
    _fn("watch_screen", "Start or stop Live Screen: keep a light, text-only sense of the user's front window "
        "(OCR, on this Mac) while you talk, when the user says 'watch my screen' or 'keep an eye on this'. Optionally "
        "watch for something they asked about ('tell me when the download finishes'): you'll be told when it seems true.",
        {"on": {"type": "boolean"}, "watch_for": {"type": "string", "description": "optional condition to watch for"}},
        ["on"]),
    _fn("ask_choice", "Ask the user a multiple-choice question with clickable options: to clarify what they mean, "
        "to let them pick between plans or options, or for a quiz question. The app shows the options and reads them "
        "out; the answer comes back to you. For a quiz, give the correct option number and a one-line explanation.",
        {"question": S, "options": {"type": "array", "items": S, "description": "2 to 6 short options"},
         "quiz": {"type": "boolean"}, "correct": {"type": "integer", "description": "quiz only: 1-based number of the right option"},
         "explanation": S, "allow_other": {"type": "boolean", "description": "also accept a free answer"}},
        ["question", "options"]),
    _fn("switch_personality", "Switch Aria's personality now, to one of the user's installed or built-in personalities, "
        "when the user asks (for example 'switch to the Mentor').", {"name": S}, ["name"]),
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

WEB_TOOLS = {"web_search", "research", "run_skill", "open_url", "web_search_and_open", "open_source", "read_page", "extract_page",
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
    "run_skill": "Let me work on that.",
    "switch_personality": "Switching now.",
    "research": "Let me research that. It takes about fifteen seconds.",
    "read_page": "Let me read it.",
    "read_file": "Let me read it.",
    "read_browser_tabs": "Let me look at your browser.",
    "find_files": "Let me search for that.",
    "extract_page": "Let me pull that out.",
    "get_video_transcript": "Let me get the transcript.",
    "web_search_and_open": "Let me find it.",
    "calendar_events": "Let me check your calendar.",
    "list_reminders": "Let me look at your reminders.",
    "reminder_lists": "Let me look at your reminders.",
    "search_conversations": "Let me look through our past conversations.",
    "read_conversation": "Let me find that conversation.",
    "mail_unread": "Let me check your mail.",
    "messages_unread": "Let me check your messages.",
    "list_shortcuts": "Let me see your shortcuts.",
}

TOOL_GUIDE = (
    "ACT FIRST. When the request is clear and a tool can do it, call the tool at once in this same reply, with no "
    "preamble and no plan; after the result, say ONE short line (for example 'Opened 3 tabs: LinkedIn, Seek, Indeed.' or "
    "'Added the reminder.'). Never say what you are going to do instead of doing it. Examples: User: open YouTube and "
    "Gmail -> call open_url with both links, then 'Opened YouTube and Gmail.' User: remind me to call Sam at 5 -> call "
    "add_reminder. User: what's on my screen -> call watch_screen or look_at_screen. Only for complex or ambiguous work "
    "(several steps, research or a plan whose scope, budget, place, time or criteria aren't given, more than 10 tabs, "
    "exports) first call ask_choice ONCE to confirm what they want, then act straight after the answer. "
    "WHAT YOU CAN DO. With your tools you can: open, switch and quit apps; read and change the "
    "calendar and reminders; search, read and open the user's files and documents (find_files, then "
    "read_file or open_file); see the tabs open in their browser and read any page (read_browser_tabs, "
    "read_page); search and research the web; look at their screen or an image when they ask; read "
    "and write notes in the Air vault and search past conversations; control volume and music; run "
    "Apple Shortcuts; read and send mail and messages; save results as Excel, Word, CSV or a note. "
    "NEVER say 'I can't' or 'I don't have access' for something a tool can do: call the tool. If a "
    "tool says a permission is missing, say which permission and how to allow it, for example: "
    "'I need Screen Recording permission: System Settings, Privacy and Security, Screen Recording, "
    "turn on Air.' If something is truly impossible, say exactly why in one sentence and offer the "
    "closest thing you can do. When the turn includes 'On screen now' context, use it to answer questions about "
    "what the user is looking at; for visual questions (a chart, photo, layout or diagram) call look_at_screen. "
    "For a clarifying question with a few clear options, a choice between plans, or a "
    "quiz question, call ask_choice instead of listing options in speech. When the user mentions their own document (my resume, my CV, my "
    "report, that PDF), find it with find_files and read it with read_file before answering; never "
    "ask them to paste or describe it first. 'Open the one you mentioned' means open it now: "
    "open_source with its number, web_search_and_open with its name, or open_file for a local file. "
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
    "Web: for one fact use web_search; for anything that needs several sources, use research. You can search, open, read and extract public pages and video transcripts, and save results as "
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
    if name in MULTI_OPEN:
        one, many = MULTI_OPEN[name]
        items = [str(x) for x in (a.get(many) or [])] + ([str(a[one])] if a.get(one) else [])
        what = ", ".join((urlparse(x).hostname or x).removeprefix("www.") if x.startswith("http") else x for x in items[:15])
        n = max(len(items), int(a.get("count") or 0))
        if a.get("all"):
            what = "all the sources"
        return f"I'm about to open {n or 'several'} tabs: {what}.{q}"
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
        loose = parse_loose_calls(text) or _json_calls(text)
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


REFUSAL = re.compile(
    r"\b(i\s*(can't|cannot|can not|am not able to|'m not able to|am unable to|'m unable to|don't have (access|the ability))|"
    r"as an ai\b|i'm (just )?an ai\b|i'm (not allowed|restricted)|i am (not allowed|restricted)|"
    r"i('m| am) qwen|developed by alibaba|i('m| am) (gemma|a google))", re.I)


_SOURCE_CLAIM = re.compile(
    r"\b(i (just )?(read|saw|found) (on|in|that (study|report|article|story|paper)|about|an? (report|article|study|post)|the news|online|somewhere)\b|"
    r"i (just )?(looked (it |that )?up|searched|checked online)\b|"
    r"(web )?search (shows|confirms|results? (show|say))|according to (my|the) search|"
    r"i('ve| have) (just )?(read|seen|found)\b|(sources?|reports?) (say|show|confirm)s?\b)", re.I)


_PRIVATE_CLAIM = re.compile(
    r"\b(you have (a|an|one|two|three|\d+) (meeting|event|appointment|call|reminder)s?\b|"
    r"(there'?s|there is|there are|you'?ve got|i see|i can see) [^.]{0,40}\b(on|in) your (calendar|reminders|inbox|mail)\b|"
    r"your (calendar|reminders|inbox) (shows?|has|says)\b|"
    r"i('ll| will| just| have|'ve)? ?(check(ed)?|look(ed)? at|pull(ed)? up|read) your (calendar|reminders|inbox|mail|messages|files)\b)|"
    r'"(event|reminder|message|mail)_?id"\s*:', re.I)


def claims_private(text: str) -> bool:
    """A reply stating the user's calendar, reminders, mail or files; only allowed when a tool ran this turn."""
    return bool(_PRIVATE_CLAIM.search(text or ""))


PRIVATE_NUDGE = ("(System note for the assistant, not from the user: you described the user's calendar, reminders, "
                 "mail or files, but no tool ran, so you don't know them. Call the right tool now (for example "
                 "list_events or list_reminders) if it matters, or answer again without stating anything about them.)")


def claims_source(text: str) -> bool:
    """A reply citing a search or reading; only allowed when a web tool ran this turn."""
    return bool(_SOURCE_CLAIM.search(text or ""))


SOURCE_NUDGE = ("(System note for the assistant, not from the user: you cited a search, a source or something "
                "you read, but no web tool ran. Call web_search now if a source matters, or answer again without "
                "claiming any source, search or reading.)")


def refusal_phrase(text: str) -> str | None:
    """The refusal or identity-slip phrase in a reply, for the log (to tell capability gaps from
    model safety refusals)."""
    m = REFUSAL.search(text or "")
    return m.group(0) if m else None


ACTION_TOOLS = NEEDS_CONFIRMATION | {"switch_personality", "open_app", "switch_to_app", "open_file", "reveal_in_finder", "music_control",
                                     "open_url", "web_search_and_open", "open_source", "save_as"}

_INTENT = re.compile(r"\b(let me (?!know)|i'll|i will|i'm going to|just a moment|one moment|give me a (moment|second)|"
                     r"right away|done|has been|have been|i've (closed|quit|moved|deleted|cancel+ed|added|set|muted|sent|created|marked))\b",
                     re.I)


# A request to DO something on the Mac or the web (act at once; no narration first).
ACT_ASK = re.compile(r"^\W*((uh+|um+|er+|hmm+|okay|ok|so|and|now|hey|hi|right|alright|well|also|then|just|please|aria|hey aria|can you|could you|would you|will you|i want you to|i need you to|i'd like you to|go ahead and)[\s,.!]+)*(open|close|quit|launch|search|look up|google|find|"
                     r"read|summari[sz]e|remind|add|create|schedule|move|delete|cancel|save|export|download|play|pause|"
                     r"skip|mute|unmute|set|turn|switch|show|watch|email|message|text|send|run|check)\b", re.I)
# Plans or announcements instead of acting ("I'll open...", "Here's what I'll do").
_ANNOUNCE = re.compile(r"\b(i'?ll|i will|i'?m going to|let me|i can|i'?d|here'?s (what|how) i'?ll|first,? i'?ll|"
                       r"i would|i'?m about to|allow me to)\s+(\w+\s+){0,3}?(open|search|look|find|read|check|create|add|"
                       r"set|save|export|pull|fetch|launch|start|run|send|remind|summari[sz]e|go|navigate|visit|browse)\b", re.I)


# "Opening GitHub and Wikipedia in new tabs." (present tense, as if it were happening) with no call.
_DOING = re.compile(r"^\W*(opening|searching|launching|pausing|playing|adding|creating|setting|reading|checking|looking up|"
                    r"pulling up|fetching|saving|exporting|switching|starting|running|sending|muting|unmuting|skipping)\b", re.I)


def announces_plan(text: str) -> bool:
    """The reply describes an action it is about to take, or is 'doing' (and so should have called a tool)."""
    return bool(_ANNOUNCE.search(text or "") or _DOING.search(text or ""))


ACT_NUDGE = ("(System note for the assistant, not from the user: you described what you would do but didn't call a "
             "tool. Call the right tool NOW, with no preamble; after the result, say one short line about what happened.)")


_TOOL_RE = None
_CALL_START = None


def _tool_regex():
    global _TOOL_RE, _CALL_START
    if _TOOL_RE is None:
        names = sorted(TOOL_NAMES, key=len, reverse=True)
        alts = "|".join(re.escape(n) + "|" + re.escape(n.replace("_", "")) for n in names)
        _TOOL_RE = re.compile(rf"\b({alts})\b\s*(\(([^()]*)\)|((?:\s*\w+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s,)]+),?)+))", re.I)
        _CALL_START = re.compile(rf"\b({alts})\s*\(", re.I)
    return _TOOL_RE


def _balanced(text: str, start: int) -> str | None:
    """The text inside the parenthesis that opens at text[start], respecting quotes and brackets."""
    depth, quote, i = 0, None, start
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return None


def _parse_args(argstr: str) -> dict:
    """key=value, key: value, or JSON-ish arguments, including lists like options: ["a", "b"]."""
    a = argstr.strip()
    if not a:
        return {}
    for candidate in (a, "{" + a + "}"):
        try:
            v = json.loads(candidate)
            if isinstance(v, dict):
                return v
        except ValueError:
            pass
    # key: value / key=value -> JSON: quote bare keys outside strings, Python literals to JSON
    js = re.sub(r'(^|[,{\s])([A-Za-z_]\w*)\s*[:=]\s*', lambda m: f'{m.group(1)}"{m.group(2)}": ', a)
    js = re.sub(r"\bTrue\b", "true", re.sub(r"\bFalse\b", "false", js))
    try:
        v = json.loads("{" + js + "}")
        if isinstance(v, dict):
            return v
    except ValueError:
        pass
    out = {}
    for k, v in re.findall(r"(\w+)\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s,)]+)", a):
        v = v.strip("\"'")
        if v.lower() in ("true", "false"):
            v = v.lower() == "true"
        else:
            try:
                v = int(v) if re.fullmatch(r"-?\d+", v) else float(v) if re.fullmatch(r"-?\d+\.\d+", v) else v
            except ValueError:
                pass
        out[k] = v
    return out


def parse_loose_calls(text: str) -> list[dict]:
    """Small models sometimes write a call as code or plain text instead of <tool_call> JSON,
    e.g. add_reminder(title="Call Mum"), Askchoice( question: "...", options: [...] ) or
    'addreminder title="Call Mum"'. Recognise those for known tools (any case, with or without
    underscores) so the call still goes through the normal path."""
    _tool_regex()
    out = []
    by_flat = {n.replace("_", "").lower(): n for n in TOOL_NAMES}
    for m in _CALL_START.finditer(text):
        name = by_flat.get(m.group(1).replace("_", "").lower())
        inner = _balanced(text, m.end() - 1)
        if name and inner is not None:
            out.append({"name": name, "arguments": _parse_args(inner)})
    if out:
        return out
    for m in _TOOL_RE.finditer(text):
        name = by_flat.get(m.group(1).replace("_", "").lower())
        args = _parse_args(m.group(4) or "")
        if name and args:
            out.append({"name": name, "arguments": args})
    return out


def _json_calls(text: str) -> list[dict]:
    """Bare JSON calls with no <tool_call> tag, e.g. the 8B writing ```json {"name": "open_url", "arguments": {...}}```
    or a list of them. Only objects naming a known tool count."""
    dec = json.JSONDecoder()
    out, i = [], 0
    while (j := text.find("{", i)) >= 0:
        try:
            obj, end = dec.raw_decode(text[j:])
        except ValueError:
            i = j + 1
            continue
        i = j + end
        if isinstance(obj, dict) and obj.get("name") in TOOL_NAMES:
            a = obj.get("arguments", obj.get("parameters")) or {}
            if isinstance(a, str):
                try:
                    a = json.loads(a)
                except ValueError:
                    a = {}
            out.append({"name": obj["name"], "arguments": a if isinstance(a, dict) else {}})
    return out


_JSON_CALL = re.compile(r'"name"\s*:\s*"(\w+)"')


def looks_like_tool_text(text: str) -> bool:
    """A sentence that is really a tool call written as text (never speak it)."""
    _tool_regex()
    t = text or ""
    return bool(_CALL_START.search(t) or _TOOL_RE.search(t)
                or any(m.group(1) in TOOL_NAMES for m in _JSON_CALL.finditer(t)))


_ACT = (r"(closed|quit|moved|deleted|cancel+ed|added|set|muted|unmuted|sent|created|marked|opened|switched|"
        r"paused|played|ran|turned|saved|exported|written|wrote|downloaded|scheduled|completed)")
_CLAIM = re.compile(
    rf"\b(i'?ve|i have|i just|i went ahead and)\b[^.!?]{{0,60}}?\b{_ACT}\b"
    rf"|\bi (just |also )?{_ACT} (it|the|your|a|that|them)\b"
    rf"|\b(is|are) now (open|closed|muted|unmuted|playing|paused|saved|set to)\b"
    rf"|\b(has|have) been (successfully )?(opened|closed|quit|muted|added|deleted|moved|created|sent|saved|exported|scheduled)\b"
    r"|\ball (done|set)\b", re.I)


_CLAIM2 = re.compile(
    r"\b(it'?s|it is|that'?s|they'?re|they are) (been )?(added|saved|set|scheduled|created|sent|deleted|moved)\b|"
    r"\byou'?ll (now )?(find|see) (it|them) in your (reminders|calendar|notes|vault|mail|messages)\b|"
    r"^\W*(done|all set|all done)\W*$|^\W*switch(ed|ing) (to|into)\b|"
    r"^\W*(opened|added|paused|created|saved|sent|scheduled|muted|unmuted|closed|quit|launched|moved|deleted|"
    r"exported|set (a|the|your|it)|started|skipped|played)\b", re.I)


def claims_action(text: str) -> bool:
    """The reply says something was done (past tense)."""
    return bool(_CLAIM.search(text or "") or _CLAIM2.search((text or "").strip()))


HONEST = "Sorry, I haven't actually done that. Could you ask me again?"


def announces_action(text: str) -> bool:
    """The reply talks about doing something but contains no tool call (a likely hallucination)."""
    return bool(_INTENT.search(text or ""))


NUDGE = ("(System note for the assistant, not from the user: you described an action but did not call "
         "a tool, so nothing happened. Call the right tool now, or say plainly that you could not do it.)")


_YES = re.compile(r"^\W*(yes|yeah|yep|yup|sure|ok(ay)?|go ahead|do it|please do|confirm(ed)?|correct|"
                  r"that'?s right|absolutely|definitely|of course)\b", re.I)
_NO = re.compile(r"\b(no|nope|don'?t|do not|stop|cancel|never ?mind|wait|not now|hold on)\b", re.I)


# Ordinals first, so "the second one" is 2, not "one".
_ORD = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "last": -1,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6}


def match_choice(text: str, options: list[str]) -> int | None:
    """Which option did the user pick (0-based)? Letters ('B', 'option b'), numbers or ordinals
    ('2', 'the second one', 'the last'), or the option's own words."""
    t = (text or "").strip().lower()
    m = re.match(r"^\W*(?:option|answer|letter|it'?s|its|i choose|i pick|i'll take|pick)?\s*\(?([a-f])\)?\W*(?:$|[.,!]|\s)", t)
    if m and len(t) <= 24:
        i = ord(m.group(1)) - 97
        if i < len(options):
            return i
    for w, n in _ORD.items():
        if re.search(rf"\b{w}\b", t) and (len(t) <= 30 or "one" in t or "option" in t):
            i = len(options) - 1 if n == -1 else n - 1
            if 0 <= i < len(options):
                return i
    def words(x: str) -> set:
        return {w for w in re.findall(r"[a-zà-ÿ0-9']+", x.lower()) if len(w) > 2}
    scores = [len(words(o) & words(t)) / max(1, len(words(o))) for o in options]
    best = max(range(len(options)), key=lambda k: scores[k]) if options else None
    if best is not None and scores[best] >= 0.5 and scores.count(scores[best]) == 1:
        return best
    return None


def spoken_choice(question: str, options: list[str]) -> str:
    letters = "ABCDEF"
    parts = [f"{letters[i]}, {o}" for i, o in enumerate(options[:6])]
    body = "; ".join(parts[:-1]) + ("; or " if len(parts) > 1 else "") + parts[-1]
    return f"{question.strip().rstrip('?')}? Is it {body}?"


def classify_reply(text: str) -> str:
    """'yes' only for a clear yes; 'no' for a refusal; otherwise 'unclear' (treated as not confirmed)."""
    t = text.strip()
    if _NO.search(t):
        return "no"
    if _YES.search(t):
        return "yes"
    return "unclear"


# ---------------- Smart fact-check: decide cheaply (rules only, no generation) ----------------

_FC_ASKED = re.compile(r"\b(check (that|this|it|again)|fact[- ]?check|source[sd]?\??|citation|are you sure|is that (true|right|correct|accurate)|"
                       r"really\?|prove it|verify|look it up|google it|search (for )?(it|that))\b", re.I)
_FC_RECENT = re.compile(r"\b(news|latest|recent(ly)?|current(ly)?|today|tonight|yesterday|tomorrow|this (week|month|year|season)|"
                        r"right now|nowadays|so far|price[sd]?|cost(s)? now|stock|shares?|exchange rate|score[sd]?|results?|standings|"
                        r"weather|forecast|schedule[sd]?|fixtures?|opening hours|open (now|today)|release[sd]?|launch(ed|es)?|"
                        r"election|poll[sd]?|who (won|is winning|is the (current )?(ceo|president|prime minister|leader|champion))|"
                        r"20(2[5-9]|3\d))\b", re.I)
_FC_CLAIM = re.compile(r"(\bright\?|\bisn'?t (it|that|he|she)\b|\baren'?t they\b|\bi (heard|read|saw) (that|somewhere|online)?|\bthey say\b|"
                       r"\bapparently\b|\bis it true\b|\bdid you know\b|\beveryone knows\b|\bscientists (say|proved)\b|"
                       r"\bso (grades|it|that|this) (doesn'?t|don'?t) matter\b|\bproves? that\b)", re.I)
_FC_SPECIFIC = re.compile(r"\b(how (many|much)|what (percent|percentage|share|proportion)|population of|statistics?|stats|"
                          r"average (salary|price|cost|age)|rate of|who said|quote|exact(ly)?|record (for|holder)|"
                          r"ranked|ranking|net worth|revenue|market (size|cap|share)|gdp)\b", re.I)
_FC_STAKES = re.compile(r"\b(dose|dosage|mg\b|milligrams?|medication|drug interactions?|side effects?|symptoms? of|"
                        r"is it (safe|legal)|legal(ly)?|law|visa|tax(es)?|interest rate|super(annuation)?|pension|"
                        r"mortgage rates?|insurance (cover|policy))\b", re.I)
_FC_SKIP = re.compile(r"^\W*(hi|hey|hello|thanks|thank you|ok(ay)?|cool|nice|great|bye|good (morning|night))\b|"
                      r"\b(what do you think|your (opinion|view|take)|would you rather|should i|how (do|can|should) i|"
                      r"tips|advice|help me|ideas? for|explain|what does .* mean|define|definition|how does .* work|"
                      r"tell me a (story|joke)|write|poem|imagine|pretend)\b", re.I)
_STOP = set("the a an is are was were be to of in on at for and or but with about what who when where why how do does did "
            "you your my me i it that this there their they them can could would should will just really tell please "
            "check sure true right".split())


def topic_words(text: str) -> set:
    return {w for w in re.findall(r"[a-z][a-z0-9']{2,}", (text or "").lower()) if w not in _STOP}


def factcheck_decision(text: str, checked: list | None = None) -> tuple[bool, str]:
    """Smart fact-check: (check online?, reason for Show thinking). Cheap rules; no extra generation."""
    t = (text or "").strip()
    if not t:
        return False, "nothing to check"
    if _FC_ASKED.search(t):
        return True, "you asked to check"
    if ACT_ASK.search(t) and re.search(r"^\W*(\w+\W+){0,6}?(remind|add|create|schedule|open|close|quit|launch|play|pause|"
                                       r"skip|mute|unmute|set|turn|switch|email|message|text|send|run|save|export|delete|"
                                       r"move|cancel)\b", t, re.I):
        return False, "a request to do something"
    words = topic_words(t)
    for prev in checked or []:
        if words and len(words & prev) >= max(1, int(0.5 * len(words))):
            return False, "already checked this topic"
    if _FC_RECENT.search(t):
        return True, "recent or time-sensitive"
    if _FC_CLAIM.search(t):
        return True, "a claim to confirm or correct"
    if _FC_STAKES.search(t) and not re.search(r"\b(explain|what is|what are|how does)\b", t, re.I):
        return True, "high stakes: specifics"
    if _FC_SPECIFIC.search(t):
        return True, "specific numbers or quotes"
    if _FC_SKIP.search(t):
        return False, "chat, opinion or advice"
    return False, "stable knowledge"


# ---------------- several sites in one turn ----------------
MULTI_OPEN = {"open_url": ("url", "urls"), "web_search_and_open": ("query", "queries"),
              "open_source": ("number", "numbers"), "read_page": ("url", "urls")}
OPEN_CAP = 8


def merge_calls(calls: list[dict]) -> list[dict]:
    """Several calls of the same open/read tool in one turn become one call with a list, in order;
    every other call is kept, in order."""
    out: list[dict] = []
    for c in calls:
        name, a = c.get("name"), dict(c.get("arguments") or {})
        if name in MULTI_OPEN:
            one, many = MULTI_OPEN[name]
            items = list(a.get(many) or []) + ([a[one]] if a.get(one) not in (None, "") else [])
            prev = next((o for o in out if o["name"] == name), None)
            if prev is not None and not a.get("all") and not a.get("count"):
                prev["arguments"].setdefault(many, []).extend(items)
                continue
            if items:
                a.pop(one, None)
                a[many] = items
        out.append({"name": name, "arguments": a})
    return out


def open_targets(name: str, a: dict, n_sources: int = 0) -> int:
    """How many tabs or pages this call would open or read."""
    if name not in MULTI_OPEN:
        return 0
    if name == "open_source" and a.get("all"):
        return n_sources
    one, many = MULTI_OPEN[name]
    n = len(a.get(many) or []) + (1 if a.get(one) not in (None, "") else 0)
    if name == "web_search_and_open" and a.get("count"):
        n = max(n, int(a.get("count") or 1))
    return n


OPEN_ASK = re.compile(r"\bopen\b.*(\b(and|,)\b.*\b(and|,)?|\b(all|these|those|the) (sources|links|results|sites)\b|"
                      r"\btop \d+\b|\b(two|three|four|five|six|seven|eight) (sites|tabs|results|links)\b)", re.I)


_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10}
_TOP_N = re.compile(r"\bopen\b.*?\b(?:the )?(?:top|first) (\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b"
                    r"(?: (?:results|links|sites|hits|pages|sources))?", re.I)


def top_n_rewrite(request: str, call: dict) -> dict:
    """'Search X and open the top 3 results': a model that only searched or researched gets
    web_search_and_open(query, count=3), so the tabs actually open."""
    m = _TOP_N.search(request or "")
    if not m or call.get("name") not in ("web_search", "research"):
        return call
    q = str((call.get("arguments") or {}).get("query") or (call.get("arguments") or {}).get("question") or "").strip()
    if not q:
        return call
    n = int(m.group(1)) if m.group(1).isdigit() else _NUM[m.group(1).lower()]
    return {"name": "web_search_and_open", "arguments": {"query": q, "count": max(1, min(n, 15))}}



_READ_URL = re.compile(r"\b(read|summari[sz]e|summary of|tl;?dr|what does|what's (on|in)|go through|skim|explain)\b", re.I)
_URL = re.compile(r"https?://[^\s<>\"')\]]+")


def read_url_request(request: str) -> list[str]:
    """Links in a request to read or summarise them (at most 5), else []."""
    urls = [u.rstrip(".,;:!?") for u in _URL.findall(request or "")]
    if not urls or not _READ_URL.search(request or "") or re.search(r"^\W*open\b", request or "", re.I):
        return []
    return list(dict.fromkeys(urls))[:5]
