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
                    text JSON {"type":"show_thinking","on":true}     keep the Thinking section in the note
                    text JSON {"type":"mic_muted","on":true}         drop the turn being heard
                    text JSON {"type":"voice_muted","on":true}       captions only, no speech
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
from urllib.parse import urlparse

from air_common import SessionRecorder, call_app_tool, emit, ensure_vault, watch_parent, write_index
from memory import (Memory, add_review_to_note, add_summary_to_note, build_summary_prompt, merge_profile, parse_json_object,
                    transcript_of)
from web_tools import Connectivity, WebSession
from vision import Vision
from research import Researcher, search as web_search_backend
from vad import FRAME, TurnDetector, use_silero
from aria_tools import (parse_speed, wants_heavy, route_brain, top_n_rewrite, read_url_request, match_choice, spoken_choice, refusal_phrase, claims_source, SOURCE_NUDGE, claims_private, PRIVATE_NUDGE, ACT_ASK, ACT_NUDGE, announces_plan, factcheck_decision, topic_words, merge_calls, open_targets, OPEN_ASK, MULTI_OPEN, VISION_TOOLS, WEB_TOOLS, NEEDS_CONFIRMATION, ON_HOLD, TOOL_GUIDE, TOOL_NAMES, TOOLS, classify_reply,
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
    "VOICE FORMAT: you are heard through a voice interface, not read. Reply in spoken English sentences: no "
    "markdown, no bullet points or numbered lists, no headings, no emojis, no URLs (except inside screen blocks "
    "described below). Spell out symbols and abbreviations as you would say them. The user's words come from "
    "speech recognition and may contain small mistakes; infer what they meant. You DO hear the user: the Mac's "
    "microphone and on-device speech recognition turn their voice into the text you get, so if they ask whether you "
    "can hear them, say yes (and if their words came through garbled, say which part was unclear). Talk to them as "
    "'you', never 'the user'. Keep it a back-and-forth; your "
    "personality sets your length and tone."
)
CHAT_STYLE = (
    "CHAT FORMAT: this is typed chat, read on screen. Use Markdown when it helps the reader: short paragraphs, "
    "bullet or numbered lists for options and steps, **bold** for key terms, a short ### heading for longer answers, "
    "and a Markdown table for comparisons. Simple questions get a plain one- or two-sentence answer. No emojis."
)
DISPLAY_RULES = (
    "SCREEN: the user also sees your reply under the orb. Your default is plain conversation, with no blocks. "
    "Use a block ONLY when the content genuinely reads better that way: comparing 3 or more items on several "
    "attributes, a process of 4 or more steps, a timeline, a hierarchy, a set of numbers, links to sources, or when "
    "the user asks for a table, diagram or links. Never for casual chat, short answers, opinions or a single fact. "
    "When you do, put it in ONE fenced block that is shown on screen "
    "and never spoken: ```table with a Markdown table, ```mermaid with a Mermaid diagram (flowchart TD, timeline, "
    "mindmap), ```links with a Markdown list of [title](url) links (only real links from tools), or ```code. "
    "Outside the block, speak a short natural summary and say it's on screen, for example: 'I've put a comparison "
    "table on screen: the iPhone wins on video, the Pixel on battery.' Never read the block aloud."
)

# Applies to every personality (the personality text comes first, this follows it).
ANSWER_FIRST = (
    "Answer the question the user actually asked, first and directly, in the terms they asked it. For "
    "topics like astrology, tarot, religion, fiction, games or hypotheticals, give the answer within "
    "that frame (for example the traditional astrological reading), then add at most one short honest "
    "note if it matters, such as 'that's the traditional reading; there's no scientific evidence for "
    "it'. Never lecture, moralise or refuse to engage with an ordinary adult topic. Correcting a false "
    "factual claim still comes first when the user states one as fact."
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


FRENCH_VOICE = "ff_siwis"
_FR = set("""le la les un une des je tu il elle nous vous ils elles est et ou de du que qui pas ne pour avec ce
c'est cest bonjour merci oui non très tres au aux sur dans mais mon ma mes ton ta ça ca être etre suis es sommes
êtes sont ai as avons avez ont voudrais veux peux s'il plaît plait comment allez bien très aussi où quand pourquoi""".split())
_EN = set("""the a an and or of to is are was you i we they it this that with for in on not do does what how
repeat after me say try again good great now let's lets means word""".split())


def is_french(text: str) -> bool:
    """Speak this sentence with the French voice? Counts French vs English function words and accents."""
    words = re.findall(r"[a-zà-ÿ']+", text.lower())
    fr = sum(w in _FR for w in words) + 2 * len(re.findall(r"[àâçéèêëîïôûùüÿœ]", text.lower()))
    en = sum(w in _EN for w in words)
    return fr > en and fr >= 2


def model_name(repo: str) -> str:
    """'mlx-community/Qwen3-4B-Instruct-2507-4bit' -> 'Qwen3 4B Instruct 2507 (4-bit)'."""
    n = repo.split("/")[-1]
    q = re.search(r"-(\d)bit$", n)
    n = re.sub(r"-\dbit$", "", n).replace("-", " ")
    n = re.sub(r"^gemma 4 26B A4B it heretic$", "Gemma 4 26B Heretic", n, flags=re.I)
    n = re.sub(r"^gemma\b", "Gemma", n)
    return n + (f" ({q.group(1)}-bit)" if q else "")


def to_ascii_quotes(s: str) -> str:
    s = re.sub(r"\s*[—–]\s*", ", ", s)
    s = _EMOJI.sub("", s)
    return (s.replace("’", "'").replace("‘", "'").replace("“", '"')
             .replace("”", '"'))


THINK_OPEN = ("<think>", "<|channel>thought")
THINK_CLOSE = ("</think>", "<channel|>")


DISPLAY_KINDS = ("table", "mermaid", "links", "code", "markdown")


def extract_blocks(text: str) -> tuple[str, list[tuple[str, str]]]:
    """Split a reply into what is spoken and what is shown: fenced blocks (```table, ```mermaid,
    ```links, ```code) and bare Markdown tables go to the screen and are never spoken."""
    blocks: list[tuple[str, str]] = []

    def take(m: re.Match) -> str:
        kind = (m.group(1) or "markdown").strip().lower()
        kind = kind if kind in DISPLAY_KINDS else ("code" if kind else "markdown")
        blocks.append((kind, m.group(2).strip("\n")))
        return " "
    spoken = re.sub(r"```([a-zA-Z]*)[ \t]*\n?(.*?)```", take, text, flags=re.S)
    spoken = re.sub(r"```.*$", " ", spoken, flags=re.S)  # an unfinished block is never spoken
    table = [ln for ln in spoken.splitlines() if ln.strip().startswith("|")]
    if len(table) >= 2:
        blocks.append(("table", "\n".join(table)))
        spoken = "\n".join(ln for ln in spoken.splitlines() if not ln.strip().startswith("|"))
    return spoken, blocks


def clean_for_speech(s: str) -> str:
    s = extract_blocks(s)[0]
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
    p.add_argument("--chat", action="store_true", help="typed Chat mode: no speech recognition, voice only for Read aloud")
    p.add_argument("--tts", default="mlx-community/Kokoro-82M-bf16")
    p.add_argument("--voice", default="af_heart")
    p.add_argument("--text-prompt", default=DEFAULT_PERSONA)
    p.add_argument("--max-tokens", type=int, default=450)
    p.add_argument("--think-budget", type=int, default=256, help="max reasoning tokens when Think first is on")
    p.add_argument("--no-tools", dest="tools", action="store_false", help="conversation only")
    p.add_argument("--draft", default="", help="draft model for speculative decoding, e.g. mlx-community/Qwen3-0.6B-4bit")
    p.add_argument("--tools-format", default="template", choices=["template", "compact", "nowrap"],
                   help="how the inlined tool schema is written (compact saves ~880 tokens)")
    p.add_argument("--persona-first", dest="persona_last", action="store_false",
                   help="old prompt layout (persona before the tool schema): slower personality switches")
    p.add_argument("--temp", type=float, default=0.7)
    p.add_argument("--thinker", default="", help="Talker + Thinker: a stronger brain for turns that need reasoning")
    p.add_argument("--thinker-draft", default="", help="draft model for the thinker (speculative decoding)")
    p.add_argument("--heavy", default="", help="heavy brain for deep tasks: cloud:anthropic:<model> or cloud:google:<model> "
                   "(the key comes from AIR_CLOUD_KEY_ANTHROPIC / AIR_CLOUD_KEY_GOOGLE); Aria asks before each use")
    p.add_argument("--cloud-context", action="store_true", help="the owner allowed sending the profile and recalled notes")
    p.add_argument("--route", default="auto", choices=["auto", "talker", "thinker"],
                   help="which brain answers when a thinker is loaded (auto: by the request)")
    p.add_argument("--silence-ms", type=int, default=600, help="pause that ends your turn")
    p.add_argument("--vad-margin-db", type=float, default=14.0, help="speech must be this far above the noise floor")
    p.add_argument("--vad-floor-db", type=float, default=-48.0, help="and above this absolute level")
    p.add_argument("--noise-mode", default="music", choices=["standard", "music", "headphones"],
                   help="turn detection: music-tolerant by default (Settings > Voice)")
    p.add_argument("--interrupt-sensitivity", type=float, default=0.5, help="0 (rarely interrupts) .. 1 (quick)")
    args = p.parse_args()

    watch_parent(args.parent_pid)
    vault = Path(args.vault)
    ensure_vault(vault)

    emit("PROGRESS", "0.02|Starting the engine|3")
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
    emit("PROGRESS", "0.06|Loading speech recognition|4")
    emit("STATUS", "Loading speech recognition (Parakeet)")
    from mlx_audio.stt.utils import load as load_stt
    # Chat mode keeps RAM for a bigger brain: no speech recognition, and the voice loads only for Read aloud.
    speech = {"stt": None if args.chat else load_stt(args.stt), "id": "" if args.chat else args.stt}
    if not args.chat:
        # Music-tolerant barge-in: Silero VAD on the CPU if onnxruntime is installed, numpy features otherwise.
        _here = Path(__file__).resolve().parent.parent
        _vad_model = next((p_ for p_ in (_here / "models" / "silero_vad.onnx", _here / "Resources" / "models" / "silero_vad.onnx")
                           if p_.exists()), _here / "models" / "silero_vad.onnx")
        emit("STATUS", "Speech detector: " + ("Silero VAD (CPU)" if use_silero(str(_vad_model)) else "built-in (numpy)"))
    emit("PROGRESS", "0.14|Loading the voice|2")
    from mlx_audio.tts.utils import load_model as load_tts
    if args.chat:
        tts = None
    else:
        emit("STATUS", "Loading voice (Kokoro)")
        tts = load_tts(args.tts)
    emit("PROGRESS", f"0.20|Loading the language model|{8 if 'Instruct-2507' in args.llm else 14}")
    emit("STATUS", f"Loading language model ({args.llm.split('/')[-1]})")
    from mlx_lm import load as load_lm, stream_generate
    from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache
    from mlx_lm.sample_utils import make_sampler
    lm, tokenizer = load_lm(args.llm)
    # Speculative decoding (Deeper brain): a small model from the same family drafts a few tokens that
    # the main model checks in one pass. Same tokenizer required; the prompt cache covers both models.
    draft = None
    if args.draft:
        try:
            draft, _ = load_lm(args.draft)
            emit("STATUS", f"Draft model for speculative decoding: {args.draft.split('/')[-1]}")
        except Exception as exc:
            emit("STATUS", f"Draft model not used: {exc}")

    # Orchestrator: route each request to a specialist "lens" (bge-small on the CPU, ~3 ms).
    router, specialists = None, {}
    _res = Path(__file__).resolve().parent.parent
    try:
        from router import Router
        _rdir = next(p_ for p_ in (_res / "models" / "bge-small", _res / "Resources" / "models" / "bge-small")
                     if (p_ / "model_quantized.onnx").exists())
        _prof = next(p_ for p_ in (_res / "professionals.json", _res / "Resources" / "professionals.json") if p_.exists())
        specialists = {p_["id"]: p_ for p_ in json.loads(_prof.read_text())["items"]
                       if p_["id"] not in ("analyst", "freespirit", "sparring")}
        router = Router(str(_rdir))
        router.set_specialists(list(specialists.values()))
        emit("STATUS", f"Orchestrator: {len(specialists)} specialists indexed")
    except Exception as exc:
        emit("STATUS", f"Orchestrator off: {exc}")

    def new_cache():
        return make_prompt_cache(lm) + (make_prompt_cache(draft) if draft is not None else [])

    emit("PROGRESS", "0.40|Warming up|4")
    emit("STATUS", f"Warming up (loaded in {time.time() - t0:.0f}s)")
    tw = time.time()
    rng = np.random.default_rng(0)
    if not args.chat:
        for secs in (1.0, 2.5, 4.0):  # realistic shapes so real turns don't pay kernel compile
            speech["stt"].generate(mx.array((rng.standard_normal(int(STT_RATE * secs)) * 0.05).astype(np.float32)))
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

    model_ids = args.llm if args.chat else f"{args.llm} + {args.stt} + {args.tts} ({args.voice})"
    voice_box = {"tts": tts}

    def ensure_tts():
        """Chat mode: the voice loads on first Read aloud (GPU thread)."""
        if voice_box["tts"] is None:
            voice_box["tts"] = load_tts(args.tts)
        return voice_box["tts"]
    # Hybrid reasoning models (Qwen3 8B/14B/30B, Gemma 4) accept enable_thinking; the 2507 Instruct models don't.
    _tpl = getattr(tokenizer, "chat_template", "") or ""
    can_think = ("<think>" in _tpl or "enable_thinking" in _tpl) and "Instruct-2507" not in args.llm
    TOOL_START = getattr(tokenizer, "tool_call_start", None) or "<tool_call>"

    memory = Memory(vault)
    # Speech speed (0.5-2x), set by voice ("speak faster", "speed 1.5"); remembered between launches.
    speed_file = Path.home() / "Library/Application Support/Air/speech.json"
    try:
        speed_box = {"v": max(0.5, min(2.0, float(json.loads(speed_file.read_text()).get("speed", 1.0))))}
    except Exception:
        speed_box = {"v": 1.0}
    net = Connectivity()
    vision = None  # created after the GPU worker exists

    def transcribe_file(wav_path: str) -> list:
        """Local Parakeet transcription of a temporary audio file (runs on the GPU thread)."""
        import wave as wavemod

        with wavemod.open(wav_path) as w:
            a = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0
        res = speech["stt"].generate(mx.array(a), chunk_duration=120.0, overlap_duration=5.0)
        return [(float(s.start), s.text.strip()) for s in getattr(res, "sentences", []) if s.text.strip()]

    MULTILINGUAL_STT = "mlx-community/parakeet-tdt-0.6b-v3"

    def use_stt(repo: str) -> None:
        """Swap the speech recogniser (GPU thread). Language personalities use the multilingual
        Parakeet v3 in place of the English v2, so RAM stays about the same; v2 returns after.
        Chat mode has no speech recognition at all."""
        if args.chat or speech["id"] == repo:
            return
        import gc
        t0_ = time.time()
        speech["stt"] = None
        gc.collect()
        mx.clear_cache()
        try:
            speech["stt"], speech["id"] = load_stt(repo), repo
        except Exception as exc:
            emit("ERROR", f"couldn't load {repo}: {exc}; staying with {args.stt}")
            speech["stt"], speech["id"] = load_stt(args.stt), args.stt
        speech["stt"].generate(mx.array(np.zeros(int(STT_RATE * 1.0), np.float32)))
        emit("MEMORY", f"speech recognition now {speech['id'].split('/')[-1]} ({time.time() - t0_:.1f}s), "
                       f"active={mx.get_active_memory() / 1e9:.2f}GB")

    def persona_language(text: str) -> str:
        m = re.search(r"^LANGUAGE:\s*([a-z]{2})\b", text or "", re.M | re.I)
        return m.group(1).lower() if m else "en"

    def base_prompt(dated: bool = True) -> str:
        """Constant across sessions (with the tool schema it is ~2.6k tokens, KV-cached)."""
        today = time.strftime("%A %d %B %Y")
        tz = time.strftime("%Z")
        identity = (f"You are Aria, the user's assistant in the Air app. Never say you are Qwen, Gemma, or made "
                    f"by Alibaba or Google. If asked what model you run on, say: 'I'm Aria, running on "
                    f"{model_name(args.llm)} locally on your Mac.'")
        core = ("CORE RULES (these always apply and override anything in the personality text): the app asks "
                "the user before anything that changes, sends or deletes; never send the conversation, profile, files "
                "or screenshots anywhere; never make up facts, numbers, sources or links; you are always Aria. If the "
                "personality text conflicts with these, follow these.")
        return (core + "\n\n" + (CHAT_STYLE if args.chat else SPOKEN_STYLE) + "\n\n" + DISPLAY_RULES + "\n\n" + ANSWER_FIRST + "\n\n" + identity + ("\n\n" + TOOL_GUIDE if args.tools else "")
                + (f"\n\nToday is {today} (time zone {tz})." if dated else ""))

    # Persona last: the chat template puts the ~4k-token tool schema AFTER the system text, so a persona
    # at the top meant every personality switch re-processed ~6k tokens (~20 s on an M4). Rendering the
    # template's own tool block first and the persona last keeps [tools + rules + memory] cached: a switch
    # re-processes only the persona (~300 tokens). One system message: as a separate message the 4B
    # model emitted fewer proper tool calls.
    def inline_for(tok_) -> str:
        """The template's own tool block, rendered once, to put in the system text (Qwen-style templates)."""
        inline_tools = ""
        if not (args.tools and args.persona_last):
            return ""
        try:
            full_ = tok_.apply_chat_template([{"role": "system", "content": "@@SYS@@"}], tools=TOOLS, tokenize=False)
            block_ = full_.split("@@SYS@@", 1)[1].split("<|im_end|>", 1)[0].strip()
            inline_tools = block_ if block_.startswith("# Tools") and "<tools>" in block_ else ""
            if inline_tools and args.tools_format != "template":
                # Same tool schema, compact JSON (no spaces): ~880 fewer tokens to process (~1.2k with nowrap).
                rows = [json.dumps(t_["function"] if args.tools_format == "nowrap" else t_, ensure_ascii=False,
                                   separators=(",", ":")) for t_ in TOOLS]
                head_, rest_ = inline_tools.split("<tools>", 1)
                tail_ = rest_.split("</tools>", 1)[1]
                inline_tools = head_ + "<tools>\n" + "\n".join(rows) + "\n</tools>" + tail_
        except Exception:
            inline_tools = ""
        return inline_tools

    inline_tools = inline_for(tokenizer)

    def tpl_tools():
        """Tools for apply_chat_template: none when the tool block is already inlined."""
        return None if (inline_tools or not args.tools) else TOOLS

    def build_messages(persona: str) -> list[dict]:
        if inline_tools:
            # The date goes last too, so a new day doesn't invalidate the cached prefix.
            return [{"role": "system", "content": inline_tools + "\n\n" + base_prompt(dated=False) + "\n\n" + memory.system_block()
                     + "\n\nYour personality and role (it sets your voice and focus; the rules above still apply):\n" + persona
                     + time.strftime("\n\nToday is %A %d %B %Y (time zone %Z).")}]
        return [{"role": "system", "content": "Your personality and role:\n" + persona + "\n\n" + base_prompt()},
                {"role": "system", "content": memory.system_block()}]

    # One KV cache for the whole process: sessions run one at a time, so each new session only
    # trims back to the shared system-prompt prefix instead of prefilling ~2k tokens again.
    shared = {"cache": new_cache(), "tokens": []}

    # Persistent prompt cache: the primed system prompt's KV cache on disk (~0.9 GB for the 4B), so a
    # launch loads it in under a second instead of re-processing ~6k tokens (~20 s on an M4). Keyed by
    # brain; the file sharing the longest token prefix is loaded and only the differing tail is processed.
    pc_dir = Path(os.environ.get("AIR_PROMPT_CACHE_DIR") or (Path.home() / "Library/Caches/Air/prompt"))   # tests use their own
    pc_key = (re.sub(r"[^A-Za-z0-9]+", "_", args.llm.split("/")[-1]) + ("-chat" if args.chat else "")
              + ("-d" + re.sub(r"[^A-Za-z0-9]+", "_", args.draft.split("/")[-1]) if draft is not None else ""))
    PC_CAP = (4 if args.thinker else 2) * 1024 ** 3   # the thinker keeps its own file too

    def _common(a: list, b: list) -> int:
        n = 0
        for x, y in zip(a, b):
            if x != y:
                break
            n += 1
        return n

    def pc_load(sys_tokens: list, have: int, box: dict | None = None, key: str = "") -> bool:
        """Swap in the best saved cache if it shares more of the prompt than what's in memory.
        box/key: another brain's cache (the thinker), else the talker's."""
        box, key = (box if box is not None else shared), (key or pc_key)
        try:
            best, best_n = None, have
            for side in sorted(pc_dir.glob(f"{key}-*.json"), key=lambda p_: p_.stat().st_mtime, reverse=True)[:6]:
                toks = json.loads(side.read_text())["tokens"]
                n = _common(toks, sys_tokens)
                if n > best_n + 256:
                    best, best_n = (side, toks), n
            if best is None:
                return False
            t_ = time.time()
            from mlx_lm.models.cache import load_prompt_cache
            cache_ = load_prompt_cache(str(best[0].with_suffix(".safetensors")))
            # Materialise now, on this thread: lazily loaded arrays stay bound to the loading thread's
            # stream, and the GPU thread then fails with "There is no Stream(cpu, 1) in current thread".
            mx.eval([a_ for c_ in cache_ for a_ in (c_.state if isinstance(c_.state, (list, tuple)) else [c_.state])])
            off_ = next((c_.offset for c_ in cache_ if hasattr(c_, "offset")), len(best[1]))
            box["cache"], box["tokens"] = cache_, best[1][:off_]
            best[0].touch()
            emit("STATUS", f"Prompt cache loaded from disk ({best_n} of {len(sys_tokens)} tokens) in {time.time() - t_:.1f}s")
            return True
        except Exception as exc:
            emit("STATUS", f"Prompt cache not used: {exc}")
            return False

    def pc_save(box: dict | None = None, key: str = "", model: str = "") -> None:
        box, key, model = (box if box is not None else shared), (key or pc_key), (model or args.llm)
        try:
            import hashlib
            from mlx_lm.models.cache import save_prompt_cache
            pc_dir.mkdir(parents=True, exist_ok=True)
            toks = list(box["tokens"])
            h = hashlib.sha1(json.dumps(toks).encode()).hexdigest()[:12]
            f_ = pc_dir / f"{key}-{h}.safetensors"
            if not f_.exists():
                t_ = time.time()
                save_prompt_cache(str(f_), box["cache"])
                (pc_dir / f"{key}-{h}.json").write_text(json.dumps({"tokens": toks, "model": model}))
                emit("STATUS", f"Prompt cache saved ({len(toks)} tokens, {f_.stat().st_size / 1e9:.2f} GB) in {time.time() - t_:.1f}s")
            # Least recently used first out, past the 2 GB cap (only Air's own cache files).
            files = sorted(pc_dir.glob("*.safetensors"), key=lambda p_: p_.stat().st_mtime, reverse=True)
            total = 0
            for p_ in files:
                total += p_.stat().st_size
                if total > PC_CAP and p_ != f_:
                    p_.unlink(missing_ok=True)
                    p_.with_suffix(".json").unlink(missing_ok=True)
        except Exception as exc:
            emit("STATUS", f"Prompt cache not saved: {exc}")

    def prime(msgs: list, disk: bool = False) -> None:
        sys_tokens = list(tokenizer.apply_chat_template(
            msgs, tools=tpl_tools(), add_generation_prompt=False,
            tokenize=True, enable_thinking=False))
        common = _common(shared["tokens"], sys_tokens)
        if disk and common < len(sys_tokens) - 256 and pc_load(sys_tokens, common):
            common = _common(shared["tokens"], sys_tokens)
        todo = len(sys_tokens) - common
        if len(shared["tokens"]) > common:
            trim_prompt_cache(shared["cache"], len(shared["tokens"]) - common)
        if common < len(sys_tokens):
            for _ in stream_generate(lm, tokenizer, sys_tokens[common:], max_tokens=1, draft_model=draft,
                                     prompt_cache=shared["cache"]):
                pass
        off = shared["cache"][0].offset
        shared["tokens"] = sys_tokens[:off]
        if disk and todo > 512:
            pc_save()

    t_prime = time.time()
    last_persona = {"text": args.text_prompt.strip() or DEFAULT_PERSONA}
    # The longest step: estimate it from the speed measured on this Mac last time (honest, not faked).
    rate_file = Path.home() / "Library/Application Support/Air/prime_rate.json"
    try:
        rate = float(json.loads(rate_file.read_text()).get(args.llm, 250.0))
    except Exception:
        rate = 250.0
    msgs0 = build_messages(last_persona["text"])
    n_tok = len(tokenizer.apply_chat_template(msgs0, tools=tpl_tools(), tokenize=True))
    emit("PROGRESS", f"0.50|Preparing your personality and memory|{n_tok / max(rate, 1):.0f}")
    prime(msgs0, disk=True)
    dt_prime = time.time() - t_prime
    try:
        rates = json.loads(rate_file.read_text()) if rate_file.exists() else {}
        rates[args.llm] = round(len(shared["tokens"]) / max(dt_prime, 0.1), 1)
        rate_file.write_text(json.dumps(rates))
    except Exception:
        pass
    emit("PROGRESS", "1.00|Ready|0")
    emit("STATUS", f"System prompt primed ({len(shared['tokens'])} tokens) in {dt_prime:.1f}s")
    lock = asyncio.Lock()
    ui_dir = Path(args.ui_dir)
    # One thread owns all GPU (MLX) work; VAD runs on the CPU stream next to it.
    gpu_jobs: queue.Queue = queue.Queue()
    idle_jobs: list = []   # generators stepped only while no job waits (GPU thread)

    def gpu_worker_main():
        # MLX streams are per thread: this thread gets its own GPU stream.
        with mx.stream(mx.new_stream(mx.gpu)):
            while True:
                try:
                    fn = gpu_jobs.get(timeout=0.05 if idle_jobs else None)
                except queue.Empty:
                    # Nothing waiting: one small step of background work (e.g. priming the thinker),
                    # so a turn that arrives meanwhile waits at most one step.
                    try:
                        next(idle_jobs[0][1])
                    except StopIteration:
                        idle_jobs.pop(0)
                    except Exception as exc:
                        idle_jobs.pop(0)
                        emit("ERROR", f"background job failed: {exc!r}")
                    continue
                try:
                    fn()
                except Exception as exc:  # keep the worker alive
                    emit("ERROR", f"model job failed: {exc!r}")

    threading.Thread(target=gpu_worker_main, name="air-gpu", daemon=True).start()

    # ---------------- Talker + Thinker ----------------
    # The loaded brain above is the talker (fast, conversational, does the tool calls). A thinker is a
    # stronger brain with its own prompt cache that answers turns needing reasoning; a heavy brain is
    # loaded only for deep tasks and unloaded after. All of them run on the one GPU thread, one at a time.
    def load_brain(repo: str, draft_repo: str = "") -> dict:
        t_ = time.time()
        lm_, tok_ = load_lm(repo)
        dr_ = None
        if draft_repo:
            try:
                dr_, _ = load_lm(draft_repo)
            except Exception as exc:
                emit("STATUS", f"thinker draft not used: {exc}")
        tpl_ = getattr(tok_, "chat_template", "") or ""
        b = {"id": repo, "lm": lm_, "tok": tok_, "draft": dr_, "tokens": [],
             "cache": make_prompt_cache(lm_) + (make_prompt_cache(dr_) if dr_ is not None else []),
             "tool_start": getattr(tok_, "tool_call_start", None) or "<tool_call>",
             "can_think": ("<think>" in tpl_ or "enable_thinking" in tpl_ or "<|channel>" in tpl_) and "Instruct-2507" not in repo,
             "inline": inline_for(tok_), "load_s": round(time.time() - t_, 1)}
        emit("MEMORY", f"{model_name(repo)} loaded in {b['load_s']}s, active={mx.get_active_memory() / 1e9:.2f}GB")
        return b

    def unload_brain(box: dict, key: str) -> None:
        import gc
        if box.get(key) is not None:
            box[key] = None
            gc.collect()
            mx.clear_cache()
            emit("MEMORY", f"{key} unloaded, active={mx.get_active_memory() / 1e9:.2f}GB")

    def cache_offset(cache) -> int | None:
        """Tokens held: hybrid models (Qwen3.5) start with linear-attention layers that have no offset."""
        return next((c_.offset for c_ in cache if hasattr(c_, "offset")), None)

    def _copy(x_):
        return None if x_ is None else (type(x_)(_copy(y_) for y_ in x_) if isinstance(x_, (list, tuple)) else x_ + 0)

    def cache_snapshot(cache) -> list:
        st_ = [(type(c_), _copy(c_.state)) for c_ in cache]
        mx.eval([x_ for _, xs_ in st_ for x_ in (xs_ if isinstance(xs_, (list, tuple)) else [xs_]) if isinstance(x_, mx.array)])
        return st_

    def cache_restore(snap: list) -> list:
        return [cls_.from_state(_copy(xs_)) for cls_, xs_ in snap]

    def brain_reset_to(b: dict, common: int) -> int:
        """Trim this brain's cache back to `common` tokens. Caches that can't be trimmed (linear-attention
        layers, e.g. Qwen3.5) start over instead; returns the tokens kept."""
        from mlx_lm.models.cache import can_trim_prompt_cache
        if len(b["tokens"]) <= common:
            return len(b["tokens"])
        if can_trim_prompt_cache(b["cache"]):
            trim_prompt_cache(b["cache"], len(b["tokens"]) - common)
            b["tokens"] = b["tokens"][:common]
            return common
        ok_ = [x_ for x_ in b.get("snaps", []) if common >= len(x_[0]) and b["tokens"][:len(x_[0])] == x_[0]]
        if ok_:
            # Back to the longest saved state that still matches; only what follows is processed again.
            snap_ = max(ok_, key=lambda x_: len(x_[0]))
            b["cache"], b["tokens"] = cache_restore(snap_[1]), list(snap_[0])
            return len(snap_[0])
        b["cache"] = make_prompt_cache(b["lm"]) + (make_prompt_cache(b["draft"]) if b["draft"] is not None else [])
        b["tokens"] = []
        return 0

    def brain_messages(b: dict, msgs: list) -> tuple[list, list | None]:
        """The conversation in this brain's own format: leading system messages merged into one (some
        templates, e.g. Qwen3.5, allow only one, first), and the talker's inlined tool block swapped for
        this brain's (or for the template's tools argument)."""
        tools_ = None if (b["inline"] or not args.tools) else TOOLS
        n_sys = 0
        while n_sys < len(msgs) and msgs[n_sys]["role"] == "system":
            n_sys += 1
        if n_sys == 0 or (n_sys == 1 and b["inline"] == inline_tools and args.chat):
            return msgs, tools_
        sys_ = "\n\n".join(m_["content"] for m_ in msgs[:n_sys])
        if not args.chat:
            # The thinker answers out loud: give the substance in a few spoken sentences (cached with the system).
            sys_ += ("\n\nTHINKER, SPOKEN: you are answering out loud for a harder question. Give the useful substance in "
                     "at most five short spoken sentences unless the user asked for detail; put any long comparison in a table "
                     "block on screen instead of reading it out.")
        if inline_tools and sys_.startswith(inline_tools):
            sys_ = sys_[len(inline_tools):].lstrip("\n")
        if b["inline"]:
            sys_ = b["inline"] + "\n\n" + sys_
        return [{"role": "system", "content": sys_}] + msgs[n_sys:], tools_

    def system_tokens(tok_, bm: list, tools_) -> list:
        """Tokens of the system part alone. Templates that refuse a system-only conversation get a
        placeholder user turn, cut off again at its start."""
        try:
            return list(tok_.apply_chat_template(bm, tools=tools_, add_generation_prompt=False, tokenize=True,
                                                 enable_thinking=False))
        except Exception:
            txt = tok_.apply_chat_template(bm + [{"role": "user", "content": "@@U@@"}], tools=tools_,
                                           add_generation_prompt=False, tokenize=False, enable_thinking=False)
            cut = txt.rfind("@@U@@")
            head = txt[:cut]
            for marker in ("<|im_start|>user", "<start_of_turn>user", "<|turn>user"):
                if marker in head:
                    head = head[:head.rfind(marker)]
                    break
            return list(tok_.encode(head, add_special_tokens=False))

    def prime_brain_steps(b: dict, msgs: list, chunk: int = 256):
        """Process the system prompt into this brain's cache, one chunk per step (a generator, stepped
        on the GPU thread while it's idle). Brains whose cache can't be trimmed (Qwen3.5) keep snapshots
        at the persona boundary and at the end, so a personality switch re-processes only the persona."""
        n_sys = next((i_ for i_, m_ in enumerate(msgs) if m_["role"] != "system"), len(msgs))
        bm, bt = brain_messages(b, msgs[:n_sys])
        t_ = time.time()
        sys_tokens = system_tokens(b["tok"], bm, bt)
        content_ = bm[0]["content"] if bm and bm[0]["role"] == "system" else ""
        cut_ = content_.find("Your personality and role")
        split_ = 0
        if cut_ > 0:
            pre_ = system_tokens(b["tok"], [{"role": "system", "content": content_[:cut_]}], bt)
            split_ = max(0, _common(pre_, sys_tokens) - 4)
        key_ = "think-" + re.sub(r"[^A-Za-z0-9]+", "_", b["id"].split("/")[-1])
        b["sys_tokens"], b["split"] = sys_tokens, split_   # where a turn snapshots the system part (see generate)
        common = _common(b["tokens"], sys_tokens)
        if common < len(sys_tokens) - 256 and pc_load(sys_tokens, common, box=b, key=key_):
            b["snaps"] = []
            common = _common(b["tokens"], sys_tokens)
        common = brain_reset_to(b, common)
        todo_ = len(sys_tokens) - common
        from mlx_lm.models.cache import can_trim_prompt_cache
        trimmable = can_trim_prompt_cache(b["cache"])
        while True:
            common = _common(b["tokens"], sys_tokens)
            if common >= len(sys_tokens):
                break
            if len(b["tokens"]) > common:      # a thinker turn ran meanwhile with another prompt
                common = brain_reset_to(b, common)
            end_ = min(len(sys_tokens), common + chunk)
            if common < split_ < end_:
                end_ = split_
            for _ in stream_generate(b["lm"], b["tok"], sys_tokens[common:end_], max_tokens=1, draft_model=b["draft"],
                                     prompt_cache=b["cache"]):
                pass
            b["tokens"] = sys_tokens[:end_]
            if not trimmable and end_ in (split_, len(sys_tokens)):
                snaps_ = [x_ for x_ in b.get("snaps", []) if b["tokens"][:len(x_[0])] == x_[0] and len(x_[0]) < end_]
                b["snaps"] = (snaps_ + [(list(b["tokens"]), cache_snapshot(b["cache"]))])[-2:]
            yield
        if not trimmable and b["tokens"] == sys_tokens and not any(x_[0] == sys_tokens for x_ in b.get("snaps", [])):
            b["snaps"] = (b.get("snaps", []) + [(list(b["tokens"]), cache_snapshot(b["cache"]))])[-2:]
        if todo_ > 512:
            pc_save(box=b, key=key_, model=b["id"])
        emit("STATUS", f"{model_name(b['id'])} primed ({len(b['tokens'])} tokens, {todo_} new) in {time.time() - t_:.1f}s")

    def prime_brain_later(b: dict, msgs: list) -> None:
        """Queue a background prime of this brain (the latest one replaces any not yet finished)."""
        idle_jobs[:] = [j_ for j_ in idle_jobs if j_[0] is not b]
        idle_jobs.append((b, prime_brain_steps(b, [dict(m_) for m_ in msgs if m_["role"] == "system"])))
        gpu_jobs.put(lambda: None)   # wake the GPU thread if it's waiting with nothing queued

    brains: dict = {"thinker": None, "heavy": None}
    from cloud import CloudBrain, display_name, parse_ref, plain_history
    heavy_cloud = parse_ref(args.heavy)
    cloud_key = os.environ.pop(f"AIR_CLOUD_KEY_{heavy_cloud[0].upper()}", "") if heavy_cloud else ""
    if heavy_cloud and not cloud_key:
        emit("STATUS", f"heavy brain {args.heavy}: no key, so it stays off")
        heavy_cloud = None
    cloud_name = display_name(heavy_cloud[0]) if heavy_cloud else ""
    if heavy_cloud:
        emit("STATUS", f"heavy brain: {cloud_name} {heavy_cloud[1]} (cloud; asks before each use)")

    def cloud_answer(messages: list, say, send_text, speak, cancelled, persona_: str, trace) -> bool:
        """Answer this turn with the cloud heavy brain. False: not possible (offline, error); answer locally."""
        if not net.online:
            say("I'm offline, so I'll answer here on the Mac.")
            return False
        system_ = (base_prompt().replace("\n\n" + TOOL_GUIDE, "")
                   + f"\n\nFor this answer you are running on {cloud_name} ({heavy_cloud[1]}) in the cloud; the user agreed. "
                     "You can't use tools here; answer from what you know and say when something may be out of date."
                   + ("\n\n" + memory.system_block() if args.cloud_context else "")
                   + "\n\nYour personality and role:\n" + persona_)
        hist = plain_history(messages, args.cloud_context)
        cb = CloudBrain(heavy_cloud[0], heavy_cloud[1], cloud_key)
        event(t="cloud", name=cloud_name, model=heavy_cloud[1])
        event(t="brain", who="heavy", why=f"{cloud_name} (cloud)")
        trace("cloud", f"Asking {cloud_name} ({heavy_cloud[1]}); sent {len(hist)} turns"
                       + (" with your profile" if args.cloud_context else ", no profile or notes"))
        full_, buf_ = "", ""
        try:
            for piece in cb.stream(system_, hist):
                if cancelled():
                    break
                full_ += piece
                buf_ += piece
                if args.chat:
                    cut = buf_.rfind("\n") + 1
                    if cut:
                        send_text(buf_[:cut])
                        buf_ = buf_[cut:]
                    continue
                while True:
                    chunk, buf_ = pop_sentence(buf_, first=False)
                    if chunk is None or not speak(chunk):
                        break
        except Exception as exc:
            emit("ERROR", f"cloud answer failed: {type(exc).__name__}")   # never the key or the request
            if not full_:
                say(f"I couldn't reach {cloud_name}, so I'll answer here on the Mac.")
                return False
        if buf_.strip() and not cancelled():
            (send_text if args.chat else speak)(buf_)
        messages.append({"role": "assistant", "content": full_.strip() or "..."})
        note_ = cb.cost_note()
        emit("CLOUD", note_)
        trace("cloud", note_)
        return True
    if args.thinker:
        try:
            brains["thinker"] = load_brain(args.thinker, args.thinker_draft)
            prime_brain_later(brains["thinker"], build_messages(last_persona["text"]))
        except Exception as exc:
            emit("ERROR", f"thinker not loaded: {exc}")
    vision = Vision(emit, gpu_jobs)

    def side_llm(msgs: list, max_tokens: int) -> str:
        """A one-off generation with its own cache (for research planning and briefs). GPU thread only."""
        chat = tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False, enable_thinking=False)
        return "".join(r.text for r in stream_generate(lm, tokenizer, chat, max_tokens=max_tokens,
                                                       sampler=make_sampler(temp=0.3)))

    async def handle_chat(request: web.Request):
        ws = web.WebSocketResponse(max_msg_size=0)
        await ws.prepare(request)
        try:
            # The previous conversation may still be closing (saving its note): wait for it briefly
            # instead of refusing, so a quick "new topic" or reconnect doesn't fail.
            await asyncio.wait_for(lock.acquire(), 15)
        except asyncio.TimeoutError:
            await ws.send_bytes(b"\x03" + b"Another conversation is already running.")
            await ws.close()
            return ws
        try:
            await run_session(request, ws)
        finally:
            lock.release()
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
        think_req = request.query.get("think") == "1"   # the thinker may reason even when the talker can't
        web_on = request.query.get("web", "1") != "0"   # online fact-check (on by default)
        # Smart (default): check only when it's needed; Always: every factual turn; Off.
        fc_mode = (request.query.get("factcheck") or "smart") if web_on else "off"
        # Orchestrator: auto (default) / ask / off. Off as well when a specialist was picked directly.
        orch_mode = request.query.get("orch") or "off"
        try:
            panel_size = max(2, min(3, int(request.query.get("panel") or 3)))
        except ValueError:
            panel_size = 3
        if router is None or personality in {p_["name"] for p_ in specialists.values()}:
            orch_mode = "off"
        allowed = [x for x in (request.query.get("specialists") or "").split(",") if x in specialists]
        if allowed and orch_mode != "off" and set(allowed) != set(router.ids):
            router.set_specialists([specialists[x] for x in allowed])
        memory.reload()  # pick up edits the owner made to Profile.md in Obsidian
        last_persona["text"] = persona
        recorder = SessionRecorder(vault, voice, persona, mode="Chat" if args.chat else "Aria", model_id=model_ids,
                                   assistant="Aria", user_side=True)
        recorder.personality = personality
        messages: list[dict] = build_messages(persona)
        # Continuity: the same conversation continues in its own note (orb, Esc, History > Continue).
        resume_q = (request.query.get("resume") or "").strip()
        if resume_q:
            try:
                note_ = Path(resume_q).resolve()
                if note_.is_file() and (vault.resolve() / "Sessions") in note_.parents:
                    prev_ = recorder.resume(note_)
                    if len(prev_) > 16:
                        # Long: carry the summary forward plus the most recent turns.
                        summ_ = re.search(r'^summary: "?(.*?)"?$', recorder.prior or "", re.M)
                        if summ_ and summ_.group(1).strip():
                            messages.append({"role": "user", "content": f"(Earlier in this conversation: {summ_.group(1).strip()})"})
                            messages.append({"role": "assistant", "content": "Got it."})
                        prev_ = prev_[-12:]
                    while prev_ and prev_[0]["role"] != "user":
                        prev_ = prev_[1:]
                    messages.extend(prev_)
                    emit("STATUS", f"continuing {note_.name} ({len(prev_)} earlier turns)")
            except Exception as exc:
                emit("STATUS", f"couldn't continue {resume_q}: {exc}")
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
            "think_req": think_req,   # Think first was asked for (the thinker can reason even if the talker can't)
            "use": None,              # the brain for this turn: None (talker) or the thinker
            "temp": min(1.2, max(0.0, float(request.query.get("temp") or args.temp))),  # personality's creativity
            "mute_voice": bool(args.chat),   # Chat: text only (Read aloud is separate)
            "checked": [],                   # topics already checked online this session (Smart fact-check)
        }
        web = WebSession(net, vault, transcribe_audio=transcribe_file)
        # Settings > Online: tabs per request (research opens many) and when to ask first.
        try:
            web.max_tabs = max(1, min(30, int(request.query.get("maxtabs") or 15)))
            confirm_tabs = max(1, int(request.query.get("confirmtabs") or 10))
        except ValueError:
            web.max_tabs, confirm_tabs = 15, 10
        recorder.web_log = web.log
        out_q: asyncio.Queue = asyncio.Queue()

        def send(kind: int, payload: bytes = b"") -> None:
            loop.call_soon_threadsafe(out_q.put_nowait, bytes([kind]) + payload)

        def event(**payload) -> None:
            send(9, json.dumps(payload, ensure_ascii=False).encode())

        show = {"on": request.query.get("showThinking") == "1"}

        def trace(kind: str, text_: str) -> None:
            """Activity trace for the Show thinking panel; kept in the note only when the panel is on."""
            event(t="trace", kind=kind, text=str(text_)[:600])
            if show["on"]:
                recorder.thinking.append((time.strftime("%H:%M:%S"), kind, str(text_)[:1500]))

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

        def make_detector(mode: str, sens: float):
            return TurnDetector(mode, sens, margin_db=args.vad_margin_db, floor_db=args.vad_floor_db)

        noise_q = request.query.get("noise") or args.noise_mode
        try:
            sens_q = float(request.query.get("sens") or args.interrupt_sensitivity)
        except ValueError:
            sens_q = args.interrupt_sensitivity
        detector = {"d": make_detector(noise_q, sens_q)}

        def vad_loop():
            """Turn detection in plain numpy (no MLX here: MLX work on a second thread stalls
            the GPU thread's TTS). 20 ms frames, band-limited energy vs an adaptive noise floor."""
            frame = FRAME  # 20 ms at 24 kHz
            buf = np.zeros(0, np.float32)
            last_music_note = 0.0
            last_miss_note = 0.0
            while not st["closed"]:
                try:
                    item = mic_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                if isinstance(item, str) and item == "MUTE":  # mic muted: drop whatever was being heard
                    utter.clear()
                    pre.clear()
                    turn.update(speaking=False, speech_ms=0.0, silence_ms=0.0)
                    buf = np.zeros(0, np.float32)
                    continue
                if isinstance(item, str):  # "END": manual end of turn
                    if utter or turn["speaking"]:
                        end_turn(manual=True)
                    continue
                buf = np.concatenate((buf, item))
                while buf.shape[0] >= frame:
                    x = buf[:frame]
                    buf = buf[frame:]
                    det = detector["d"]
                    rejected = det.rejected
                    speech = det.is_speech(x)
                    if det.missed is not None:
                        # Something speech-like that never counted: log it so misses can be tuned.
                        peak, thr, over_music = det.missed
                        det.missed = None
                        if time.monotonic() - last_miss_note > 8:
                            last_miss_note = time.monotonic()
                            trace("vad", f"Possible missed start: speech probability peaked at {peak:.2f} "
                                         f"(needs {thr:.2f}){' with music playing' if over_music else ''}")
                    if (det.rejected > rejected and det.music_present and assistant_audible()
                            and time.monotonic() - last_music_note > 20):
                        # Loud sound that isn't you talking: say so once, quietly, and keep going.
                        last_music_note = time.monotonic()
                        trace("noise", "Music detected; I'll keep talking")
                        event(t="music", on=True)
                    if turn["speaking"] or speech:
                        utter.append(x)
                    else:
                        pre.append(x)
                        if len(pre) > 8:  # 160 ms pre-roll
                            pre.pop(0)
                    if speech:
                        turn["speech_ms"] += 20
                        turn["silence_ms"] = 0
                        if not turn["speaking"] and turn["speech_ms"] >= det.onset_ms(assistant_audible()):
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
            set_state("checking" if name in ("web_search", "research", "read_page", "extract_page", "web_search_and_open",
                                             "get_video_transcript", "transcribe_video_audio") else "working")
            event(t="tool", phase="start", name=name)
            if name in VISION_TOOLS:
                result = look(name, clean)
            elif name in WEB_TOOLS:
                try:
                    if name == "save_as":
                        result = web.save_as(clean.get("format", ""), clean.get("title"), clean.get("content"))
                    elif name in MULTI_OPEN:
                        result = web.multi(name, clean)   # one site or a list, each in a new tab
                    elif name == "run_skill":
                        result = run_skill(str(clean.get("skill") or ""), str(clean.get("text") or ""))
                    elif name == "research":
                        g0 = st["gen"]

                        def progress(step: str, text_: str) -> None:
                            event(t="research", step=step, text=text_)
                            trace("research", text_)

                        deep = str(clean.get("deep", "")).lower() in ("true", "1", "yes")
                        result = Researcher(web, side_llm, progress,
                                            lambda: st["gen"] != g0 or st["closed"]).run(
                            str(clean.get("question") or ""), deep=deep)
                        if result.get("ok") and getattr(web, "last_research", None):
                            recorder.research.append(web.last_research)
                            emit("RESEARCH", f"{'deep ' if deep else ''}{web.last_research['seconds']}s "
                                             f"(read {web.last_research['read_s']}s) via {web.last_research['backend']}: "
                                             + ", ".join(p_['domain'] for p_ in web.last_research['pages']))
                    else:
                        arg = clean.get("query") or clean.get("url") or ""
                        result = getattr(web, name)(arg)
                        if name == "web_search" and result.get("ok"):
                            st["checked"].append(topic_words(arg))   # follow-ups on this topic skip the check
                except Exception as exc:
                    result = {"ok": False, "error": f"{name} failed: {exc}"}
            elif name == "watch_screen":
                result = call_app_tool(name, clean, timeout=10)
                if result.get("ok"):
                    on = str(clean.get("on", True)).lower() not in ("false", "0", "no")
                    st["watch_for"] = str(clean.get("watch_for") or "").strip() if on else ""
                    if on:
                        # The first look arrives within a few seconds: wait for it, so a question about
                        # what's on screen now gets answered now (a static page never 'changes').
                        t_end = time.monotonic() + 4.0
                        while time.monotonic() < t_end and not ((st.get("screen") or {}).get("text")):
                            time.sleep(0.2)
                        sc_ = st.get("screen") or {}
                        if sc_.get("text") and not sc_.get("excluded"):
                            result["on_screen_now"] = f"{sc_.get('app')} - {sc_.get('window')}:\n{sc_['text'][:1500]}"
                        result["note"] = ("Say briefly that you're watching their screen. If the user asked about what "
                                          "is on screen, answer it now from on_screen_now."
                                          + (f" If '{st['watch_for']}' is not visible yet, you'll be told when it seems true."
                                             if st["watch_for"] else ""))
            elif name == "switch_personality":
                result = call_app_tool(name, clean, timeout=10)
                if result.get("ok") and result.get("persona"):
                    # New personality from the next reply on (the cache re-primes once, ~20 s on the 4B).
                    messages[0] = build_messages(result["persona"])[0]
                    recorder.personality = result.get("name", recorder.personality)
                    event(t="personality", name=result.get("name", ""))
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
            trace("result", f"{name}: {str(summary)[:300]}")
            event(t="tool", phase="end", name=name, ok=bool(result.get("ok")), summary=str(summary)[:160])
            if name in WEB_TOOLS and result.get("ok") and web.last_sources:
                trace("sources", ", ".join(urlparse(s_["url"]).hostname or s_["url"] for s_ in web.last_sources[:10]))
                event(t="sources", items=[{"title": s_["title"], "url": s_["url"]} for s_ in web.last_sources[:6]])
            if name == "save_as" and result.get("ok") and result.get("path"):
                event(t="file", path=result["path"])
            set_state("thinking")
            return result

        def transcribe(audio) -> str:
            rng = np.random.default_rng()
            dith = (rng.standard_normal(audio.shape[0]) * 3e-4).astype(np.float32)
            text_ = speech["stt"].generate(mx.array(audio + dith)).text.strip()
            if not text_ and audio.shape[0] > STT_RATE * 0.5:
                # Parakeet can return nothing for a very short word padded with silence: retry tighter.
                core = audio[int(STT_RATE * 0.12): max(int(STT_RATE * 0.3), audio.shape[0] - int(STT_RATE * 0.3))]
                text_ = speech["stt"].generate(mx.array(core + dith[: core.shape[0]])).text.strip()
            return text_

        def net_hint(text_: str = "") -> str:
            if not args.tools:
                return ""
            if not net.online:
                return ("(Offline right now: web tools are unavailable. Answer from your own knowledge; for "
                        "factual claims, mention briefly that you couldn't verify online.)")
            if fc_mode == "smart":
                check, why = factcheck_decision(text_, st["checked"])
                if check:
                    trace("factcheck", f"Fact-check: checking ({why})")
                    return ("(Fact-check needed here (" + why + "): call web_search first, then say briefly what the "
                            "answer is based on. For the user's own files, screen, browser, calendar or Mac, use those tools instead.)")
                trace("factcheck", f"Fact-check: skipped ({why})")
                return ("(No web search needed for this turn: answer from your own knowledge. If you are genuinely unsure "
                        "of a specific fact, say so in a few words. Use the user's own tools for their files, screen or Mac.)")
            if web_on:
                return ("(Online: for factual claims about the world such as facts, figures, dates, people or "
                        "recent events, call web_search first, then say briefly what the answer is based on. "
                        "For the user's own files, screen, browser, calendar or Mac, use those tools instead.)")
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

        OWN_DOC = re.compile(r"\bmy (resume|résumé|cv|cover letter|report|essay|thesis|assignment|document|doc|file|pdf|"
                             r"notes|draft|portfolio|spreadsheet|slides|deck)\b", re.I)

        RESEARCH_ASK = re.compile(r"^\W*(please\s+)?(can you\s+|could you\s+)?(do (a |some )?(deep |quick )?research|research|"
                                  r"look into|dig into|investigate|compare)\b|\bdeep research\b", re.I)

        QUIZ_ASK = re.compile(r"\b(quiz|test me|multiple choice)\b", re.I)
        SWITCH_ASK = re.compile(r"\b(switch|change|swap)\s+(to|into|personality|your personality)\b|\bbe (the|my) \w+ (now|instead)\b|"
                                r"\bback to (aria|normal|yourself)\b|\bswitch (me )?back\b", re.I)
        BROWSER_ASK = re.compile(r"\b(my )?(browser|tabs?|safari|chrome|tabbit|arc)\b", re.I)
        WATCH_ASK = re.compile(r"\b(watch|keep an eye on|monitor|follow) (my|the) screen\b|\blive screen\b", re.I)
        CAL_ASK = re.compile(r"\b(my )?(calendar|schedule|agenda|meetings?|appointments?|reminders?)\b|"
                             r"\bwhat (do|have) i (got|have)\b|\bam i (free|busy)\b", re.I)
        NEWS_ASK = re.compile(r"\b(news|this week|today'?s|latest|recent(ly)?|just happened|headlines?|current events)\b", re.I)

        def run_skill(skill: str, text_: str) -> dict:
            """Run an installed skill (a Fabric pattern) on text, the last page or the last research."""
            path = Path.home() / "Library/Application Support/Air/personalities/skills.json"
            try:
                skills = json.loads(path.read_text())
            except Exception:
                skills = []
            if not skills:
                return {"ok": False, "error": "No skills are installed. Install some in Personalities, Skills."}
            key = re.sub(r"[^a-z]", "", skill.lower())
            match = next((s_ for s_ in skills if re.sub(r"[^a-z]", "", s_["name"].lower()) == key), None) or \
                next((s_ for s_ in skills if key and key in re.sub(r"[^a-z]", "", s_["name"].lower())), None)
            if not match:
                return {"ok": False, "error": f"No installed skill called {skill}. Installed: " + ", ".join(s_["name"] for s_ in skills)}
            source = text_.strip()
            if not source and web.last_extract:
                source = web.last_extract.get("text") or ""
            if not source:
                return {"ok": False, "error": "Give me some text, or open or research something first."}
            out = side_llm([{"role": "system", "content": match["prompt"][:6000]},
                            {"role": "user", "content": source[:7000]}], 600).strip()
            web.last_extract = {"kind": "text", "title": match["name"], "url": "", "text": out, "tables": []}
            return {"ok": True, "summary": f"Ran {match['name']}", "output": out[:2500],
                    "note": "Tell the user the gist in a few spoken sentences; offer to save it with save_as."}

        PANEL_ASK = re.compile(r"\b(get|give me|convene|call) (a|the|me a) panel\b|\bpanel (on|of|for) (this|that|it)\b|"
                               r"\b(a few|several|different|multiple) (expert )?(views|opinions|perspectives)\b", re.I)

        def run_panel(text_: str, announce=None) -> str:
            """Panel: 2-3 specialists each give a short take (sequential, side generations); Aria synthesises."""
            if router is None or not PANEL_ASK.search(text_):
                return ""
            topic = PANEL_ASK.sub("", text_).strip(" ,.?:") or text_
            router.route(topic)
            ids = [i_ for i_ in getattr(router, "last_order", []) if i_ in specialists][:panel_size]
            if len(ids) < 2:
                return ""
            if announce:
                announce("Let me get a few views on that.")
            # The question this panel is about: the request itself, or the previous user turn for "a panel on this".
            subject = topic if len(topic.split()) > 3 else next(
                (m_["content"].split("\n\n(")[0] for m_ in reversed(messages) if m_["role"] == "user"), topic)
            takes = []
            for i_ in ids:
                if st["closed"]:
                    break
                p_ = specialists[i_]
                t0_ = time.monotonic()
                take = side_llm([{"role": "system", "content": f"You are a {p_['name']} ({p_['role']}). Expertise: {p_['expertise']}. "
                                  f"Methods: {', '.join(p_.get('frameworks') or [])}. Give your honest take in at most two short "
                                  "spoken sentences, from your expertise only. No lists, no preamble."},
                                 {"role": "user", "content": subject[:800]}], 60).strip()
                takes.append((p_, take))
                event(t="panel", id=p_["id"], name=p_["name"], emoji=p_.get("emoji", ""), take=take)
                trace("panel", f"{p_['name']} ({time.monotonic() - t0_:.1f}s): {take}")
            if not takes:
                return ""
            st["lens_on"] = "panel"   # the thinker writes the combined answer
            lines = "\n".join(f"- {p_['name']}: {t_}" for p_, t_ in takes)
            return (f"(Panel takes on this question:\n{lines}\nGive the combined answer in your own voice: what they agree on, "
                    "where they disagree and why, and your recommendation. At most five spoken sentences; name each "
                    "expert briefly. Don't repeat their takes word for word.)")

        def route_lens(text_: str) -> str:
            """Lens mode: one generation, answered through the best-fitting specialist's expertise."""
            if orch_mode == "off" or not text_.strip():
                return ""
            t_ = time.monotonic()
            # "Ask the Mentor ...": that specialist's lens for this turn, no routing.
            low_ = " " + re.sub(r"[^a-z ]", " ", text_.lower()) + " "
            named = None
            if re.search(r"\b(ask|what would|what does|get) ", low_):
                for p_ in specialists.values():
                    base_ = re.sub(r"\s*\(.*?\)", "", p_["name"]).lower()      # "Lawyer (general information)" -> "lawyer"
                    if re.search(r"\b(ask|what would|what does|get) (the |my |a |an )?" + re.escape(base_) + r"\b", low_):
                        named = p_
                        break
            res = ({"mode": "lens", "id": named["id"], "name": named["name"], "reason": "you asked for them", "score": 1.0}
                   if named else router.route(text_))
            if res["mode"] == "unsure":
                # Close call: the loaded brain picks from the shortlist (a few tokens).
                cands = [specialists[c] for c in res.get("candidates", [])[:4]]
                menu = "\n".join(f"{chr(65 + i)}) {c['name']}: {c['expertise']}" for i, c in enumerate(cands))
                ans = side_llm([{"role": "user", "content": f"Request: {text_[:400]}\n\nWhich expert fits best?\n{menu}\n"
                                 f"{chr(65 + len(cands))}) none of them\nAnswer with one letter."}], 2).strip().upper()[:1]
                k = ord(ans) - 65 if ans else -1
                if 0 <= k < len(cands):
                    res.update(mode="lens", id=cands[k]["id"], name=cands[k]["name"], reason="picked by the brain")
                else:
                    res.update(mode="aria", reason="the brain kept it with Aria")
            ms = (time.monotonic() - t_) * 1000
            if res["mode"] != "lens":
                trace("route", f"Aria answers herself ({res.get('reason', '')}, {ms:.0f} ms)")
                return ""
            p_ = specialists[res["id"]]
            trace("route", f"Lens: {p_['name']} ({res.get('reason')}, match {res.get('score', 0):.2f}, {ms:.0f} ms)")
            event(t="lens", id=p_["id"], name=p_["name"], emoji=p_.get("emoji", ""), ask=orch_mode == "ask")
            if orch_mode != "ask":
                st["lens_on"] = p_["name"]   # a specialist lens is answered by the thinker
            if orch_mode == "ask":
                return (f"(This looks like a question for the {p_['name']}. Ask the user in one short sentence whether "
                        f"they'd like the {p_['name']}'s view; if they've already said yes, answer through it.)")
            return (f"(Specialist lens for this answer: think like a {p_['name']} ({p_['role']}). Expertise: {p_['expertise']}. "
                    f"Methods: {', '.join(p_.get('frameworks') or [])}. Always: {'; '.join((p_.get('dos') or [])[:2])}. "
                    f"Never: {'; '.join((p_.get('donts') or [])[:2])}. Stay Aria with the same rules; don't mention the lens."
                    + (f" When it matters, say: {p_['disclaimer']}" if p_.get("disclaimer") else "") + ")")

        def with_recall(text_: str, announce=None) -> str:
            """Attach older conversations that match this turn (BM25) and the network state. Added to
            the user message, after the cached prefix, so the KV cache stays valid."""
            hint = net_hint(text_)
            lens = run_panel(text_, announce) if orch_mode != "off" else ""
            lens = lens or route_lens(text_)
            if lens:
                hint = (lens + "\n" + hint).strip()
            sc = st.get("screen")
            if sc and not sc.get("excluded"):
                hint = (f"(On screen now, from Live Screen: {sc['app']} - {sc['window']}. Visible text (OCR, may be partial): "
                        f"{sc['text'][:900]})\n" + hint).strip()
            elif sc and sc.get("excluded"):
                hint = (f"(The front app, {sc['app']}, is on the excluded list: its screen is not read.)\n" + hint).strip()
            if args.tools and net.online and RESEARCH_ASK.search(text_):
                hint = ("(The user asked for research: call the research tool with their question"
                        + (" and deep set to true" if re.search(r"\b(deep|thorough|in-depth|in depth)\b", text_, re.I) else "")
                        + ", not web_search.) " + hint).strip()
            if args.tools and net.online and NEWS_ASK.search(text_):
                hint = ("(This asks about news or recent events: call web_search first and answer only from it.) "
                        + hint).strip()
            if args.tools and BROWSER_ASK.search(text_):
                hint = ("(This is about the user's browser: call read_browser_tabs first, then read_page on a tab "
                        "if needed. It needs no Screen Recording.) " + hint).strip()
            if args.tools and OPEN_ASK.search(text_):
                hint = ("(To open several sites, make ONE call with a list: open_url with urls, web_search_and_open "
                        "with queries (one per site) or with query and count for the top N results, or open_source "
                        "with all true when they say 'the sources' or 'these sources'.) " + hint).strip()
            if args.tools and WATCH_ASK.search(text_):
                hint = ("(The user wants Live Screen: call watch_screen with on true now. If they also asked about what "
                        "is on screen, answer from the on_screen_now it returns.) " + hint).strip()
            if args.tools and CAL_ASK.search(text_) and not re.search(r"\b(add|create|schedule|set|book|move|delete|remind me)\b", text_, re.I):
                hint = ("(This asks about the user's calendar or reminders: call calendar_events (or list_reminders) "
                        "first and answer only from what it returns.) " + hint).strip()
            if args.tools and SWITCH_ASK.search(text_):
                hint = ("(The user wants a different personality: call switch_personality with the name they said.) "
                        + hint).strip()
            if args.tools and QUIZ_ASK.search(text_):
                hint = ("(For a quiz: ask one question at a time with ask_choice, quiz true, with the correct option and a "
                        "one-line explanation. Don't say the answer first.) " + hint).strip()
            if args.tools and OWN_DOC.search(text_):
                hint = ("(This is about the user's own document on this Mac: find it with find_files and read it "
                        "with read_file, then answer.) " + hint).strip()
            hits = [h for h in memory.recall(text_) if h["name"] not in st["recalled"]]
            if not hits:
                return f"{text_}\n\n{hint}" if hint else text_
            for h in hits:
                st["recalled"].add(h["name"])
            emit("MEMORY", "recalled " + ", ".join(h["name"] for h in hits))
            trace("memory", "Recalled: " + "; ".join(f"{h['date']}: {h['summary'][:120]}" for h in hits))
            notes = "\n".join(f"- {h['date']}: {h['summary']}" for h in hits)
            return f"{text_}\n\n(Memory that may be relevant, from earlier conversations:\n{notes})" + (f"\n{hint}" if hint else "")

        def reply(audio, t_end: float, gen_id: int, typed: str | None = None, image: str | None = None):
            def cancelled() -> bool:
                return gen_id != st["gen"] or st["closed"]

            spoken: list[str] = []
            first_audio = None
            marks: dict = {}
            perf = {"tts_s": 0.0, "audio_s": 0.0, "tokens": 0, "llm_s": 0.0, "new_tokens": 0}

            def send_text(seg: str) -> None:
                """Chat: raw Markdown to the screen (no speech clean-up)."""
                nonlocal first_audio
                if first_audio is None:
                    first_audio = time.monotonic()
                    marks.setdefault("chunk1", first_audio)
                spoken.append(seg.strip())
                send(2, seg.encode())

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
                if st.get("mute_voice"):
                    # Voice muted: captions only, no speech synthesis.
                    if first_audio is None:
                        first_audio = time.monotonic()
                    send(2, (chunk + " ").encode())
                    spoken.append(chunk)
                    return not cancelled()
                v_ = FRENCH_VOICE if lang["code"] == "fr" and is_french(chunk) else voice
                for res in tts.generate(chunk, voice=v_, lang_code=v_[0], speed=speed_box["v"]):
                    if st.get("mute_voice"):
                        break  # muted mid-sentence: stop the audio, keep the caption
                    if cancelled():
                        return False
                    pcm = np.array(res.audio).reshape(-1)
                    pcm16 = (np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes()
                    now = time.monotonic()
                    if first_audio is None:
                        first_audio = now
                        set_state("speaking")
                    # Paused: the page holds the audio, so the playback clock is frozen at the pause.
                    clock = st["paused_at"] if st.get("paused_at") else now
                    st["play_until"] = max(st["play_until"], clock) + pcm.shape[0] / TTS_RATE
                    perf["audio_s"] += pcm.shape[0] / TTS_RATE
                    send(1, pcm16)
                send(2, (chunk + " ").encode())
                spoken.append(chunk)
                perf["tts_s"] += time.monotonic() - t_tts
                return True

            guard = {"hit": False}
            act_req = {"on": False}
            think_text: list[str] = []
            disp = {"on": False, "text": ""}
            shown: list[tuple[str, str]] = []

            def show_block(raw: str) -> None:
                first, _, rest = raw.partition("\n")
                tag = first.strip().lower()
                if tag in DISPLAY_KINDS:
                    kind, body = tag, rest
                elif not tag:
                    kind, body = "markdown", rest
                elif re.fullmatch(r"[a-z0-9+#-]{1,15}", tag):
                    kind, body = "code", rest          # ```python and the like
                else:
                    kind, body = "markdown", raw       # no tag: the first line is content
                body = body.strip("\n")
                if args.tools and kind in ("code", "markdown") and looks_like_tool_text(body) and parse_tool_calls(body):
                    emit("DISPLAY", "a tool call written in a code block: run, not shown")
                    return
                # Trivial structure isn't worth the screen: a table needs 2+ data rows, a diagram 3+ links.
                rows = [ln for ln in body.splitlines() if ln.strip().startswith("|") and not re.fullmatch(r"[|:\-\s]+", ln.strip())]
                if (kind == "table" and len(rows) < 3) or (kind == "mermaid" and len(re.findall(r"--|==", body)) < 3):
                    emit("DISPLAY", f"dropped a trivial {kind}")
                    return
                if body.strip():
                    shown.append((kind, body))
                    event(t="display", kind=kind, body=body[:20000])
                    trace("display", f"{kind} shown on screen ({len(body)} characters)")

            def generate(live: bool = True, check_claims: bool = False, check_sources: bool = False) -> tuple[str, list[dict]]:
                """Stream one assistant message; speak it sentence by sentence.
                Returns (text, tool_calls). Text after a <tool_call> tag is not spoken."""
                B = st.get("use")   # None: the talker; else the thinker or heavy brain for this turn
                if B is None:
                    lm_, tok_, draft_, cache_, tool_start_ = lm, tokenizer, draft, st["cache"], TOOL_START
                    msgs_, tools_, think_ = messages, tpl_tools(), think
                else:
                    lm_, tok_, draft_, cache_, tool_start_ = B["lm"], B["tok"], B["draft"], B["cache"], B["tool_start"]
                    (msgs_, tools_), think_ = brain_messages(B, messages), st.get("think_req", False) and B["can_think"]
                prompt = list(tok_.apply_chat_template(
                    msgs_, tools=tools_, add_generation_prompt=True, tokenize=True,
                    enable_thinking=think_ and not act_req["on"]))   # a clear action needs no reasoning first
                cached = st["cache_tokens"] if B is None else B["tokens"]
                common = 0
                for x, y in zip(cached, prompt):
                    if x != y:
                        break
                    common += 1
                common = min(common, len(prompt) - 1)
                if len(cached) > common:
                    if B is None:
                        trim_prompt_cache(cache_, len(cached) - common)
                    else:
                        common = brain_reset_to(B, common)
                        cache_ = B["cache"]
                if B is not None and B.get("sys_tokens"):
                    from mlx_lm.models.cache import can_trim_prompt_cache
                    sys_ = B["sys_tokens"]
                    end_sys = _common(prompt, sys_)    # the system part as this prompt renders it
                    if not can_trim_prompt_cache(cache_) and common < end_sys and end_sys >= len(sys_) - 8:
                        sys_ = prompt[:end_sys]
                        # Can't trim this cache: process the system part on its own and keep a snapshot
                        # there (and at the persona boundary), so later turns only redo the conversation.
                        for stop_ in [x_ for x_ in (min(B.get("split", 0), end_sys), end_sys) if x_ > common]:
                            for _ in stream_generate(lm_, tok_, prompt[common:stop_], max_tokens=1, draft_model=draft_,
                                                     prompt_cache=cache_):
                                pass
                            common = stop_
                            B["tokens"] = prompt[:common]
                            B["snaps"] = ([x_ for x_ in B.get("snaps", []) if len(x_[0]) < common
                                           and B["tokens"][:len(x_[0])] == x_[0]] + [(list(B["tokens"]), cache_snapshot(cache_))])[-2:]
                    if not can_trim_prompt_cache(cache_) and len(prompt) - common > 64:
                        # Also keep the state at the end of this prompt: the next turn (or the next tool
                        # round) shares it exactly, so only the new messages are processed then.
                        for _ in stream_generate(lm_, tok_, prompt[common:-1], max_tokens=1, draft_model=draft_,
                                                 prompt_cache=cache_):
                            pass
                        common = len(prompt) - 1
                        B["tokens"] = prompt[:common]
                        keep_ = [x_ for x_ in B.get("snaps", []) if B["tokens"][:len(x_[0])] == x_[0]]
                        base_ = [x_ for x_ in keep_ if len(x_[0]) <= len(sys_)][-2:]   # system and persona states
                        B["snaps"] = base_ + [(list(B["tokens"]), cache_snapshot(cache_))]
                feed = prompt[common:]
                perf["new_tokens"] += len(feed)
                sampler = make_sampler(temp=st.get("temp", args.temp), top_p=0.9)
                full = ""
                buf = ""
                in_think = False
                in_tool = False
                t0 = time.monotonic()
                tts_before = perf["tts_s"]
                segments = [feed]
                think_tokens = 0
                think_buf: list[str] = []
                think_flush = [time.monotonic()]
                while segments:
                    seg = segments.pop(0)
                    for resp in stream_generate(lm_, tok_, seg, max_tokens=args.max_tokens, draft_model=draft_,
                                                sampler=sampler, prompt_cache=cache_):
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
                                segments.append(tok_.encode(close, add_special_tokens=False))
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
                            thought = piece.split(closer, 1)[0] if closer else piece
                            for o_ in THINK_OPEN:
                                thought = thought.replace(o_, "")
                            think_buf.append(thought)
                            if closer or time.monotonic() - think_flush[0] > 0.15:
                                event(t="thought", text="".join(think_buf))
                                think_text.append("".join(think_buf))
                                think_buf.clear()
                                think_flush[0] = time.monotonic()
                            if closer:
                                in_think = False
                                piece = piece.split(closer, 1)[1]
                            else:
                                continue
                        buf += piece
                        if tool_start_ in buf:
                            buf, _ = buf.split(tool_start_, 1)
                            in_tool = True
                        # Display blocks: everything between ``` fences goes to the screen, not the voice.
                        while live and (disp["on"] or "```" in buf):
                            if not disp["on"]:
                                before, buf = buf.split("```", 1)
                                if before.strip():
                                    speak(before)
                                disp.update(on=True, text="")
                            if "```" in buf:
                                inner, buf = buf.split("```", 1)
                                if check_sources and claims_private(disp["text"] + inner):
                                    guard["source"] = "private"   # a made-up calendar/mail record: never show it
                                    live = False
                                    disp["on"] = False
                                    break
                                show_block(disp["text"] + inner)
                                disp["on"] = False
                            else:
                                disp["text"] += buf
                                buf = ""
                                break
                        if buf.endswith("`"):
                            continue  # maybe the start of a fence: wait for more
                        if not live:
                            continue
                        if args.chat:
                            # Typed chat: keep the Markdown (lists, headings, bold) and the line breaks; send whole
                            # lines (or long runs) so the guards still see complete sentences first.
                            cut = buf.rfind("\n") + 1 or (len(buf) if len(buf) > 160 and buf.endswith(" ") else 0)
                            if cut:
                                seg, buf = buf[:cut], buf[cut:]
                                if args.tools and looks_like_tool_text(seg):
                                    live = False
                                    continue
                                if check_claims and act_req["on"] and announces_plan(seg):
                                    guard["plan"] = True
                                    live = False
                                    continue
                                if check_sources and (claims_source(seg) or claims_private(seg)):
                                    guard["source"] = "private" if claims_private(seg) else True
                                    live = False
                                    continue
                                send_text(seg)
                            continue
                        while True:
                            chunk, buf = pop_sentence(buf, first=not spoken or len(spoken) == marks.get("hold", -1))
                            if chunk is None:
                                break
                            if args.tools and looks_like_tool_text(chunk):
                                live = False  # a tool call written as text: parse it, never speak it
                                break
                            if check_claims and act_req["on"] and announces_plan(chunk):
                                # "I'll open ..." with no tool call yet: don't voice the plan; act instead.
                                guard["plan"] = True
                                live = False
                                break
                            if check_claims and claims_action(chunk):
                                # Would claim an action that no tool performed: stop speaking here.
                                guard["hit"] = True
                                live = False
                                break
                            if check_sources and (claims_source(chunk) or claims_private(chunk)):
                                # Would cite a search or reading, or the user's calendar/files, that no tool gave: stop here.
                                guard["source"] = "private" if claims_private(chunk) else True
                                live = False
                                break
                            if not speak(chunk):
                                break
                        if cancelled():
                            break
                    if cancelled():
                        break
                if live and args.chat and not cancelled() and buf.strip():
                    if not (args.tools and looks_like_tool_text(buf)) and not (check_claims and act_req["on"] and announces_plan(buf)):
                        send_text(buf)
                    buf = ""
                if live and not cancelled() and buf.strip():
                    if args.tools and looks_like_tool_text(buf):
                        pass
                    elif check_claims and claims_action(buf):
                        guard["hit"] = True
                    elif check_sources and (claims_source(buf) or claims_private(buf)):
                        guard["source"] = "private" if claims_private(buf) else True
                    else:
                        speak(buf)
                perf["llm_s"] += (time.monotonic() - t0) - (perf["tts_s"] - tts_before)
                offset = cache_offset(cache_)
                gen_tokens = tok_.encode(full, add_special_tokens=False) if full else []
                if B is None:
                    st["cache_tokens"] = (prompt + gen_tokens)[:offset] if offset is not None else []
                    if offset is None:
                        st["cache"] = shared["cache"] = new_cache()
                    shared["tokens"] = st["cache_tokens"]
                else:
                    B["tokens"] = (prompt + gen_tokens)[:offset] if offset is not None else []
                    if offset is None:
                        B["cache"] = make_prompt_cache(B["lm"]) + (make_prompt_cache(B["draft"]) if B["draft"] is not None else [])
                if think_buf:
                    event(t="thought", text="".join(think_buf))
                    think_text.append("".join(think_buf))
                if think_text and show["on"]:
                    recorder.thinking.append((time.strftime("%H:%M:%S"), "reasoning", "".join(think_text).strip()[:4000]))
                think_text.clear()
                if os.environ.get("AIR_DEBUG_GEN") == "1":
                    emit("GEN", repr(full[:400]))
                # Parse calls from the answer only: a call drafted inside the reasoning is not a call.
                answer = re.sub(r"<think>.*?</think>|<\|channel>.*?<channel\|>", "", full, flags=re.S)
                calls = parse_tool_calls(answer) or (parse_tool_calls(full) if tool_start_ in full else [])
                text = answer
                text = re.sub(r"<\|?[a-z_\"]+\|?>", "", text.split(tool_start_, 1)[0]).strip()
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
                if re.search(r"^\W*(let'?s )?(start )?(a )?(new (topic|conversation|chat)|start (over|fresh)|fresh start)\W*$", text, re.I):
                    # The app ends this conversation and starts a fresh one (a new note).
                    recorder.add_text(text, "You", new_line=True)
                    trace("conversation", "New topic: starting a new conversation")
                    event(t="new_topic")
                    set_state("listening")
                    return
                if (new_speed := parse_speed(text, speed_box["v"])) is not None:
                    recorder.add_text(text, "You", new_line=True)
                    speed_box["v"] = new_speed
                    try:
                        speed_file.parent.mkdir(parents=True, exist_ok=True)
                        speed_file.write_text(json.dumps({"speed": new_speed}))
                    except OSError:
                        pass
                    event(t="speed", value=new_speed)
                    trace("voice", f"Speech speed {new_speed:g}x")
                    msg_ = "Back to normal speed." if new_speed == 1.0 else f"Okay, {new_speed:g} times speed."
                    if not args.chat:
                        speak(msg_)
                    else:
                        send_text(msg_)
                    recorder.add_text(msg_, "Aria", new_line=True)
                    set_state("listening")
                    return
                extra_ctx = ""
                if image:
                    # An attached image (Chat): the vision model describes it for this turn; the file stays local.
                    set_state("checking")
                    try:
                        seen = vision.describe(image, text or "Describe this image.", context="An image the user attached in chat.")
                        extra_ctx = f"\n\n(The user attached an image. What it shows: {seen.get('summary', '')})"
                        trace("result", f"image: {seen.get('summary', '')[:200]}")
                    except Exception as exc:
                        extra_ctx = f"\n\n(The user attached an image, but it couldn't be read: {exc})"
                internal = text.startswith("(Screen watch:")   # a nudge from Live Screen, not something you said
                if not internal:
                    send(5, text.encode())
                    trace("heard", text)
                    spoke_at = (t_end - (audio.shape[0] / STT_RATE if audio is not None else 0)) - recorder.start_mono
                    recorder.add_segment(spoke_at, "You", text)
                else:
                    trace("screen", text.strip("()"))

                asked = st.pop("pending_choice", None)
                if asked is not None:
                    opts = asked["options"]
                    idx = asked.get("clicked")
                    idx = idx if idx is not None else match_choice(text, opts)
                    if idx is None and not asked.get("allow_other"):
                        # Not an answer: treat it as a new request, and tell the model the question went unanswered.
                        event(t="choice_done", index=-1)
                        messages.append(tool_message({"user_said": text, "answered": False}))
                    else:
                        chosen = opts[idx] if idx is not None else text
                        res_ = {"user_said": text, "chosen": chosen, "index": (idx + 1) if idx is not None else None}
                        correct = None
                        if asked.get("quiz") and isinstance(asked.get("correct"), int):
                            correct = idx is not None and idx + 1 == asked["correct"]
                            res_["correct"] = correct
                            res_["right_answer"] = opts[asked["correct"] - 1] if 0 < asked["correct"] <= len(opts) else None
                        event(t="choice_done", index=idx if idx is not None else -1, correct=correct,
                              explanation=str(asked.get("explanation") or "")[:300])
                        recorder.choices.append((asked["question"], opts, chosen, correct))
                        trace("result", f"choice: {chosen}" + ("" if correct is None else (" (correct)" if correct else " (wrong)")))
                        messages.append(tool_message(res_))
                        text = f"(Answered: {chosen})"
                        messages.append({"role": "user", "content": "(I answered the question above.)"})
                        asked = "done"
                pending = st.pop("pending", None) if asked != "done" else None
                confirmed_ok = False
                cloud_go = local_go = False
                last_result: dict = {}
                if (pc_ := st.pop("pending_cloud", None)) is not None and pending is None:
                    v_ = classify_reply(text)
                    event(t="confirm_done", answer=v_)
                    if v_ in ("yes", "no"):
                        cloud_go, local_go = v_ == "yes", v_ == "no"
                        messages.append({"role": "user", "content": f"{text} ({'use ' + pc_ if cloud_go else 'answer here on the Mac'})"})
                        trace("cloud", f"{pc_}: {'yes' if cloud_go else 'no, answered locally'}")
                if cloud_go or local_go:
                    pass
                elif pending is not None:
                    verdict = classify_reply(text)
                    event(t="confirm_done", answer=verdict)
                    if verdict == "yes":
                        result = run_tool(pending["name"], pending["args"], f'confirmed ("{text}")')
                        confirmed_ok = bool(result.get("ok"))
                        last_result["r"] = result
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
                            messages.append({"role": "user", "content": with_recall(text, speak) + extra_ctx})
                else:
                    messages.append({"role": "user", "content": with_recall(text, speak) + extra_ctx})

                t_llm = time.monotonic()
                said_parts: list[str] = []
                used_tool = False
                nudged = False
                src_nudged = False
                plan_nudged = False
                act_req["on"] = bool(args.tools and ACT_ASK.search(text or ""))
                acted = confirmed_ok
                st["use"] = None
                if brains["thinker"] is None:
                    st.pop("lens_on", None)
                if brains["thinker"] is not None and not internal:
                    who_, why_ = ("thinker", "forced") if args.route == "thinker" else ("talker", "forced") \
                        if args.route == "talker" else route_brain(text, act_req["on"])
                    lens_ = st.pop("lens_on", None)
                    if lens_ and who_ == "talker" and not act_req["on"] and args.route == "auto":
                        who_, why_ = "thinker", f"the {lens_} lens"
                    emit("ROUTE", f"{who_} ({why_}): {text[:100]!r}")
                    if who_ == "talker":
                        event(t="brain", who="talker", why=why_)
                    if who_ == "thinker":
                        st["use"] = brains["thinker"]
                        trace("brain", f"Thinker ({model_name(brains['thinker']['id'])}): {why_}")
                        event(t="brain", who="thinker", why=why_)
                ask_cloud = ""
                if heavy_cloud is not None and not internal:
                    hv_, named_ = wants_heavy(text) if not (cloud_go or local_go) else (False, False)
                    if cloud_go or (hv_ and named_):
                        st["use"] = "cloud"
                    elif local_go:
                        st["use"] = brains["thinker"]
                    elif hv_ and not act_req["on"]:
                        ask_cloud = cloud_name

                def say(text_: str) -> None:
                    before_ = len(spoken)
                    text_, blocks_ = extract_blocks(text_)
                    for k_, b_ in blocks_:
                        show_block(k_ + "\n" + b_)
                    rest = text_
                    while True:
                        chunk, rest = pop_sentence(rest, first=not spoken)
                        if chunk is None or not speak(chunk):
                            break
                    if rest.strip() and not cancelled():
                        speak(rest)
                    said_parts.extend(spoken[before_:])

                if (switched := st.pop("announce", None)):
                    say(f"Switched to {switched}.")
                if st["use"] is not None and not args.chat and not act_req["on"] and not ask_cloud:
                    # The talker keeps the conversation going while the thinker works.
                    say(("Let me dig into that.", "Good question; give me a moment.", "Let me think that through.")[len(st["latencies"]) % 3])
                    marks["filler"] = True
                    marks["hold"] = len(spoken)
                rounds = 8
                if ask_cloud:
                    # Local by default: ask before anything goes to the cloud.
                    q_ = (f"This looks like a big one. Should I use {ask_cloud} for it? Only your question and this "
                          f"conversation go to {'Anthropic' if ask_cloud == 'Claude' else 'Google'}.")
                    st["pending_cloud"] = ask_cloud
                    event(t="confirm", tool="cloud", text=q_)
                    say(q_)
                    messages.append({"role": "assistant", "content": q_})
                    rounds = 0
                elif st["use"] == "cloud":
                    if cloud_answer(messages, say, send_text, speak, cancelled, persona, trace):
                        rounds = 0
                    else:
                        st["use"] = brains["thinker"]
                queued: list[dict] = []   # further tool calls from the same reply, run in order
                if args.tools and (read_ := read_url_request(text)):
                    # "Read/summarise <link>": read it first instead of answering from memory.
                    queued.append({"name": "read_page", "arguments": {"urls": read_}})
                    emit("TOOLCALL", f"read request with a link: read_page {read_}")
                for _round in range(rounds):  # at most a few tool calls per turn
                    # The first answer streams live for speed. After a tool has run, the follow-up is
                    # checked before it is spoken, so a claim that something was done can be caught.
                    # Stream live; when no action has run yet, each sentence is checked before it is
                    # spoken so a claim like "I've closed it" can't be voiced without a tool call.
                    guard["hit"] = False
                    guard["source"] = False
                    guard["plan"] = False
                    before = len(spoken)
                    if queued:
                        reply_text, calls = "", [queued.pop(0)]
                    else:
                        reply_text, calls = generate(True, check_claims=bool(args.tools and not acted),
                                                     check_sources=bool(args.tools and not used_tool and not src_nudged))
                        if len(calls) > 1:
                            calls = merge_calls(calls)
                            queued = calls[1:]
                            emit("TOOLCALL", f"{len(calls)} tool calls in one reply: " + ", ".join(c["name"] for c in calls))
                    live = True
                    said_parts += spoken[before:]
                    if cancelled():
                        break
                    if calls:
                        if not live and reply_text and not guard.get("plan"):
                            say(reply_text)
                    elif (used_tool or confirmed_ok) and not reply_text.strip() and len(spoken) == before and last_result.get("r"):
                        # Some brains (Gemma E4B) end with nothing after a tool: say what it did, briefly.
                        r_ = last_result["r"]
                        line_ = (str(r_.get("summary") or "").strip() or "Done.") if r_.get("ok") else \
                            ("That didn't work: " + str(r_.get("error") or "something went wrong").strip())
                        line_ = line_ if line_.endswith((".", "!", "?")) else line_ + "."
                        say(line_)
                        messages.append({"role": "assistant", "content": line_})
                        break
                    else:
                        if guard["source"] and not src_nudged:
                            src_nudged = True
                            private = guard["source"] == "private"
                            emit("TOOLCALL", f"nudge: {'stated private data' if private else 'cited a source'} without a tool: {reply_text[:120]!r}")
                            messages.append({"role": "assistant", "content": reply_text})
                            messages.append({"role": "user", "content": PRIVATE_NUDGE if private else SOURCE_NUDGE})
                            continue
                        # A clear action request answered with a plan, or with a short line and no tool
                        # ("Pause the music."), gets one nudge to act; questions and refusals don't.
                        echo_ = (not acted and reply_text and len(reply_text.split()) <= 20 and "?" not in reply_text
                                 and not refusal_phrase(reply_text))
                        if act_req["on"] and not used_tool and (guard.get("plan") or announces_plan(reply_text) or echo_):
                            if not plan_nudged:
                                plan_nudged = True
                                emit("TOOLCALL", f"nudge: announced instead of acting: {reply_text[:120]!r}")
                                trace("act", "Described the action instead of doing it: asked to act now")
                                messages.append({"role": "assistant", "content": reply_text})
                                messages.append({"role": "user", "content": ACT_NUDGE})
                                continue
                            # Still no tool: offer a one-click retry instead of a promise.
                            event(t="doit", text=text)
                            trace("act", "Still no tool call: showing a 'Do it' button")
                            say("I didn't manage to do that. Tap Do it to try again.")
                            break
                        # A claim is only suspicious if no action tool actually ran in this turn.
                        suspicious = args.tools and not acted and (
                            guard["hit"] or claims_action(reply_text) or (used_tool and announces_action(reply_text)))
                        if suspicious and not nudged:
                            nudged = True
                            emit("TOOLCALL", f"nudge: reply announced an action without a tool call: {reply_text[:120]!r}")
                            if claims_action(reply_text) and not guard["hit"]:
                                # Only when the claim was already spoken; a caught one was never voiced.
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
                    if (re_ := top_n_rewrite(text, call)) is not call:
                        emit("TOOLCALL", f"top-N request: {call['name']} became web_search_and_open {re_['arguments']}")
                        call = re_
                    name, targs = call["name"], dict(call["arguments"])
                    trace("call", f"{name}({json.dumps(call['arguments'], ensure_ascii=False)})")
                    messages.append({"role": "assistant", "content": reply_text,
                                     "tool_calls": [{"type": "function",
                                                     "function": {"name": name, "arguments": targs}}]})
                    if name == "ask_choice":
                        opts = []
                        for o in (targs.get("options") or []):
                            o = str(o).strip()
                            if o and o.casefold() not in {x.casefold() for x in opts}:
                                opts.append(o)   # identical options make a useless question
                        opts = opts[:6]
                        if len(opts) >= 2:
                            q = str(targs.get("question") or "").strip()
                            st["pending_choice"] = {"question": q, "options": opts, "quiz": bool(targs.get("quiz")),
                                                    "correct": targs.get("correct"), "explanation": targs.get("explanation"),
                                                    "allow_other": bool(targs.get("allow_other"))}
                            event(t="choice", question=q, options=opts, quiz=bool(targs.get("quiz")),
                                  allow_other=bool(targs.get("allow_other")))
                            say(spoken_choice(q, opts))
                            emit("TOOLCALL", f"ask_choice {json.dumps(targs)[:200]} awaiting an answer")
                            break
                        # Not enough options: tell the model, never forward it to the app.
                        messages.append(tool_message({"ok": False, "error": "ask_choice needs a question and 2 to 6 different options."}))
                        continue
                    if name in MULTI_OPEN:
                        targs = merge_calls([{"name": name, "arguments": targs}])[0]["arguments"]
                    n_open = open_targets(name, targs, len(web.last_sources or []))
                    if n_open > web.max_tabs:
                        messages.append(tool_message({"ok": False, "error": f"That's {n_open} pages; the limit is {web.max_tabs} at once "
                                                      "(Settings, Online). Ask the user which ones, or open the first ones."}))
                        continue
                    if name in NEEDS_CONFIRMATION or (name != "read_page" and n_open > confirm_tabs):
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
                    last_result["r"] = result
                    marks.setdefault("tool_end", time.monotonic())
                    if name in ACTION_TOOLS and result.get("ok"):
                        acted = True
                    messages.append(tool_message(result))

                said = " ".join(said_parts).strip()
                if (rp := refusal_phrase(said)):
                    emit("REFUSAL", f"{rp!r} in reply to {text[:120]!r}: {said[:240]!r}")
                interrupted = cancelled() and not st["closed"]
                if said or shown:
                    md = ""
                    for kind_, body_ in shown:
                        md += ("\n\n" + body_) if kind_ in ("table", "links", "markdown") else f"\n\n```{'mermaid' if kind_ == 'mermaid' else ''}\n{body_}\n```"
                    recorder.add_segment((first_audio or time.monotonic()) - recorder.start_mono, "Aria",
                                         said + (" [interrupted]" if interrupted else "") + md)
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

        lang = {"code": persona_language(persona)}

        def prime_session():
            if lang["code"] != "en":
                use_stt(MULTILINGUAL_STT)
            prime(messages)
            st["cache_tokens"] = shared["tokens"]
            if brains["thinker"] is not None:
                prime_brain_later(brains["thinker"], messages)   # in the background; talker turns go first

        gpu_jobs.put(prime_session)
        emit("STATUS", f"session start mode=Aria voice={voice} think={think} personality={personality or 'Custom'}")
        trace("personality", f"Personality: {personality or 'Custom'}")
        await ws.send_bytes(b"\x00")
        event(t="note", path=str(recorder.path), resumed=recorder.prior is not None)
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
                    elif data.get("type") == "noise":
                        # Settings > Voice: background noise handling and interrupt sensitivity, live.
                        try:
                            sens_ = float(data.get("sensitivity", detector["d"].sensitivity))
                        except (TypeError, ValueError):
                            sens_ = detector["d"].sensitivity
                        detector["d"] = make_detector(str(data.get("mode") or detector["d"].mode), sens_)
                        trace("noise", f"Background noise handling: {detector['d'].mode}, sensitivity {sens_:.2f}")
                    elif data.get("type") == "pause":
                        # The page suspended (or resumed) its audio: nothing plays or is heard meanwhile.
                        now_ = time.monotonic()
                        if data.get("on"):
                            st["paused_at"] = st.get("paused_at") or now_
                            trace("pause", "Paused")
                        elif st.get("paused_at"):
                            held = now_ - st["paused_at"]
                            if st["play_until"] > st["paused_at"]:
                                st["play_until"] += held
                            st["paused_at"] = 0.0
                            trace("pause", f"Resumed after {held:.0f} s")
                    elif data.get("type") == "persona":
                        if data.get("temp") is not None:
                            try:
                                st["temp"] = min(1.2, max(0.0, float(data["temp"])))
                            except (TypeError, ValueError):
                                pass
                        new = str(data.get("text") or "").strip()
                        name_ = str(data.get("name") or "").strip()[:40] or "Custom"
                        built = build_messages(new)[0] if new else None
                        if built and built["content"] != messages[0]["content"]:
                            # Next reply uses it: the system prompt changes, so the KV cache re-primes once.
                            messages[0] = built
                            recorder.personality = name_
                            lang["code"] = persona_language(new)
                            gpu_jobs.put(lambda: use_stt(MULTILINGUAL_STT if lang["code"] != "en" else args.stt))

                            def reprime():
                                # Re-prime now, in the background, so the next reply doesn't pay for it.
                                if st["busy"]:
                                    return
                                prime(messages)
                                st["cache_tokens"] = shared["tokens"]
                                if brains["thinker"] is not None:
                                    prime_brain_later(brains["thinker"], messages)
                            gpu_jobs.put(reprime)
                            st["announce"] = name_
                            emit("STATUS", f"personality switched to {name_}")
                            trace("personality", f"Personality: {name_}")
                            event(t="personality", name=name_)
                    elif data.get("type") == "screen_context":
                        if not data.get("active"):
                            st["screen"] = None
                            st["watch_for"] = ""
                            trace("screen", "Stopped watching the screen")
                        else:
                            prev = st.get("screen") or {}
                            st["screen"] = {k: str(data.get(k) or "")[:1500] for k in ("app", "window", "text")}
                            st["screen"]["excluded"] = bool(data.get("excluded"))
                            key = (st["screen"]["app"], st["screen"]["window"])
                            if not st["screen"]["excluded"] and key not in recorder.watched:
                                recorder.watched.append(key)
                            if (prev.get("app"), prev.get("window")) != key:
                                trace("screen", f"Watching: {key[0]} - {key[1]}" if not st["screen"]["excluded"] else f"{key[0]} is excluded: not read")
                            cond = st.get("watch_for")
                            if cond and st["screen"]["text"] and not st["busy"] and not st["screen"]["excluded"]:
                                snap = dict(st["screen"])

                                def check(c=cond, sc=snap):
                                    ans = side_llm([{"role": "user", "content": (
                                        f"Screen text (OCR) from {sc['app']} - {sc['window']}:\n{sc['text'][:1200]}\n\n"
                                        f"Does this show that: {c}? Answer only yes or no.")}], 3).strip().lower()
                                    if ans.startswith("yes") and st.get("watch_for") == c and not st["busy"]:
                                        st["watch_for"] = ""
                                        g_ = st["gen"] + 1
                                        st["gen"] = g_
                                        st["busy"] = True
                                        reply(None, time.monotonic(), g_,
                                              typed=f"(Screen watch: '{c}' now looks true on screen. Tell the user in one short sentence.)")
                                gpu_jobs.put(check)
                    elif data.get("type") == "show_thinking":
                        show["on"] = bool(data.get("on"))
                    elif data.get("type") == "mic_muted":
                        if data.get("on"):
                            mic_q.put("MUTE")
                    elif data.get("type") == "voice_muted":
                        st["mute_voice"] = bool(data.get("on"))
                        if st["mute_voice"]:
                            st["play_until"] = 0.0
                            send(6)  # stop what's playing now
                    elif data.get("type") == "choice" and st.get("pending_choice"):
                        # A clicked or keyed option: answer it like a spoken turn.
                        try:
                            st["pending_choice"]["clicked"] = int(data.get("index"))
                        except (TypeError, ValueError):
                            pass
                        typed = str(data.get("text") or "")[:200] or "(chose an option)"
                        if assistant_audible():
                            barge_in()
                        gen_id = st["gen"] + 1
                        st["gen"] = gen_id
                        st["busy"] = True
                        set_state("thinking")
                        gpu_jobs.put(lambda t_=typed, g_=gen_id, e_=time.monotonic(): reply(None, e_, g_, typed=t_))
                    elif data.get("type") == "say" and data.get("image"):
                        img = str(data.get("image"))
                        if os.path.isfile(img):
                            typed = str(data.get("text", ""))[:2000]
                            gen_id = st["gen"] + 1
                            st["gen"] = gen_id
                            st["busy"] = True
                            set_state("thinking")
                            gpu_jobs.put(lambda t_=typed, g_=gen_id, i_=img, e_=time.monotonic(): reply(None, e_, g_, typed=t_, image=i_))
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
            while deferred_notes:   # summaries put off while this conversation ran
                gpu_jobs.put(lambda p=deferred_notes.pop(0): remember(p))
            if speech["id"] != args.stt:
                gpu_jobs.put(lambda: use_stt(args.stt))
            lats = st["latencies"]
            if lats:
                emit("STATUS", f"session end: {len(lats)} replies, latency median "
                               f"{sorted(lats)[len(lats) // 2]:.2f}s, max {max(lats):.2f}s, "
                               f"peak {mx.get_peak_memory() / 1e9:.2f}GB")
            else:
                emit("STATUS", "session end")
            await send_task

    deferred_notes: list[Path] = []

    def remember(note: Path) -> None:
        """After a session: summary into the note, new facts into Profile.md, then re-prime."""
        t0 = time.time()
        try:
            prompt = build_summary_prompt(vault, transcript_of(note))
            chat = tokenizer.apply_chat_template([{"role": "user", "content": prompt}],
                                                 add_generation_prompt=True, tokenize=False,
                                                 enable_thinking=False)
            parts = []
            for r in stream_generate(lm, tokenizer, chat, max_tokens=800, sampler=make_sampler(temp=0.2)):
                if lock.locked():
                    # A new conversation started: it goes first; this summary runs after it ends.
                    deferred_notes.append(note)
                    emit("MEMORY", f"summary deferred after {time.time() - t0:.1f}s: a new conversation started")
                    return
                parts.append(r.text)
            out = "".join(parts)
            data = parse_json_object(out)
            summary = str(data.get("summary", "")).strip()
            if summary:
                add_summary_to_note(note, summary)
            if str(data.get("review", "")).strip():
                add_review_to_note(note, str(data["review"]))
            n = merge_profile(vault, data, data.get("resolved_threads") or [])
            write_index(vault)
            memory.reload()
            emit("MEMORY", f"saved summary and {n} profile updates in {time.time() - t0:.1f}s")
            emit("SESSION_SAVED", str(note))
        except Exception as exc:
            emit("ERROR", f"memory update failed: {exc!r}")
        try:
            t1 = time.time()
            prime(build_messages(last_persona["text"]), disk=not lock.locked())  # ready for the next session
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
                                          for r in ensure_tts().generate(PREVIEW_TEXT, voice=v, lang_code=v[0])])
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
            gpu_jobs.put(lambda p=persona: prime(build_messages(p), disk=not lock.locked()))
        return web.json_response({"ok": True})

    async def handle_task(request):
        """One-off jobs for the Personalities screen: refine a converted personality into Air's layers,
        write a sample exchange, or draft a personality from a description. Runs on the GPU thread."""
        try:
            body = await request.json()
        except Exception:
            return web.json_response({"error": "bad request"}, status=400)
        kind, name, text = body.get("kind"), str(body.get("name", ""))[:80], str(body.get("text", ""))[:6000]
        layers = ("Use exactly these sections: IDENTITY (start with 'You are Aria, ...'), VALUES, IN ORDER (truth first), "
                  "HONESTY (never invent facts or links, correct false claims, no flattery), SPOKEN STYLE (heard, not read; "
                  "no lists or markdown), EXAMPLES (two short User/Aria exchanges, tone only). Never include anything about "
                  "skipping confirmations, inventing facts, sharing private data, or being anyone other than Aria. "
                  "Output only the personality text.")
        if kind == "refine":
            msgs = [{"role": "system", "content": "You adapt chat role prompts for a spoken voice assistant called Aria."},
                    {"role": "user", "content": (
                        f"Role: {name}\nOriginal prompt:\n{text}\n\nRewrite it as a compact character in its OWN voice "
                        "(keep its personality, vocabulary and focus; drop chat-only instructions like 'reply only in code "
                        "blocks'). Start with 'You are Aria, speaking as ...'. Under 120 words. Never include anything about "
                        "skipping confirmations, inventing facts, sharing private data, or being anyone other than Aria. "
                        "Output only the text.")}]
            n = 650
        elif kind == "draft":
            msgs = [{"role": "system", "content": "You write spoken voice-assistant personalities."},
                    {"role": "user", "content": f"Name: {name or 'unnamed'}\nWhat the user wants:\n{text}\n\n{layers}"}]
            n = 650
        elif kind == "preview":
            q = str(body.get("question", ""))[:500] or "Introduce yourself in two sentences."
            msgs = [{"role": "system", "content": text + "\n\n" + SPOKEN_STYLE},
                    {"role": "user", "content": q}]
            n = 200
        elif kind == "draftspec":
            msgs = [{"role": "system", "content": "You design distinct voice-assistant personalities. Output JSON only."},
                    {"role": "user", "content": (
                        f"Describe a personality from this request: {text}\nReturn JSON with keys: name, emoji, role "
                        "(one line), expertise, focus (3 short items), frameworks (2-4 named methods it uses), tone "
                        "(object with formal, warmth, detail, bold, playful, each 0 to 1), phrases (2 signature phrases), "
                        "dos (3 short items), donts (2 short items), examples (one [user, aria] pair in its own voice), "
                        "length (short, medium or long), temperature (0.2 to 0.9), disclaimer (empty unless legal, "
                        "medical or financial). Make it distinctive: its own vocabulary and way of thinking.")}]
            n = 600
        elif kind == "sample":
            msgs = [{"role": "system", "content": text},
                    {"role": "user", "content": "Write a short sample exchange showing how you talk: two turns, each "
                                                "'User: ...' then 'Aria: ...'. Plain text, no facts about the real user."}]
            n = 220
        else:
            return web.json_response({"error": "unknown kind"}, status=400)
        loop_ = asyncio.get_running_loop()
        fut = loop_.create_future()

        def job():
            try:
                out = side_llm(msgs, n).strip()
            except Exception as exc:
                out = ""
                emit("TASK", f"{kind} failed: {exc}")
            loop_.call_soon_threadsafe(fut.set_result, out)

        gpu_jobs.put(job)
        out = await fut
        emit("TASK", f"{kind} for {name!r}: {len(out)} chars")
        return web.json_response({"text": out})

    async def handle_speak(request):
        """Read aloud (Chat): synthesise text with the chosen voice, returned as WAV."""
        text = (request.query.get("text") or "")[:4000]
        voice_ = request.query.get("voice") or args.voice
        if voice_ not in VOICES:
            voice_ = args.voice
        if not text.strip():
            return web.Response(status=400)
        loop_ = asyncio.get_running_loop()
        fut = loop_.create_future()

        def job():
            import io
            import wave as wavemod
            try:
                parts = [np.array(r.audio).reshape(-1) for r in ensure_tts().generate(clean_for_speech(text), voice=voice_, lang_code=voice_[0],
                                                                                  speed=speed_box["v"])]
                pcm = (np.clip(np.concatenate(parts) if parts else np.zeros(1), -1, 1) * 32767).astype("<i2")
                buf = io.BytesIO()
                with wavemod.open(buf, "wb") as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(TTS_RATE); w.writeframes(pcm.tobytes())
                out = buf.getvalue()
            except Exception as exc:
                emit("ERROR", f"read aloud failed: {exc}")
                out = b""
            loop_.call_soon_threadsafe(fut.set_result, out)

        gpu_jobs.put(job)
        data = await fut
        return web.Response(body=data, content_type="audio/wav") if data else web.Response(status=500)

    async def handle_status(_):
        return web.json_response({"ready": True, "busy": lock.locked(), "mode": "aria", "can_think": can_think,
                                  "online": net.online,
                                  "voices": VOICES})

    app = web.Application()
    app.router.add_get("/", handle_root)
    app.router.add_get("/api/chat", handle_chat)
    app.router.add_get("/api/status", handle_status)
    app.router.add_post("/api/prime", handle_prime)
    app.router.add_post("/api/task", handle_task)
    app.router.add_get("/api/preview", handle_preview)
    app.router.add_get("/api/speak", handle_speak)
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
