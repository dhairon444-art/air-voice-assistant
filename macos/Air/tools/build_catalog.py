"""Build Air's Personality Marketplace catalogue from permissively licensed sources.

  python build_catalog.py <sources_dir> <out.json>

<sources_dir> holds:
  prompts.csv          f/prompts.chat prompt data, CC0 1.0 (LICENSE-CC0 in that repo)
  fabric/data/patterns danielmiessler/Fabric patterns, MIT
  personanexus/*.yaml  PersonaNexus/personanexus archetypes, MIT (optional)

Every entry records its source URL, author and licence. Imported text is untrusted: lines that
try to override Air's core rules (confirmations, privacy, never inventing facts or URLs, Aria's
identity) are removed, and Air's core rules are always added after any personality anyway.
The layered spec made here is a template conversion; the app refines it with the local model on
install and caches the result.
"""

from __future__ import annotations

import csv
import hashlib
import json
import re
import sys
from datetime import date
from pathlib import Path

PROMPTS_URL = "https://github.com/f/prompts.chat"
FABRIC_URL = "https://github.com/danielmiessler/Fabric"
NEXUS_URL = "https://github.com/PersonaNexus/personanexus"

CATEGORIES = [
    ("Spiritual & Astrology", "🔮", r"astrolog|horoscope|tarot|zodiac|spiritual|meditat|dream interpret|numerolog|buddh|monk|yoga|religio"),
    ("Coaching & Wellbeing", "🌱", r"coach|therap|mental health|wellness|wellbeing|motivat|life coach|relationship|self-help|mindful|fitness|personal trainer|nutrition|dietit|sleep|stress"),
    ("Career", "💼", r"career|recruit|interview|resume|cv\b|job|hiring|linkedin|salary|negotiat"),
    ("Business & Marketing", "📈", r"marketing|advertis|brand|seo|sales|business|startup|entrepreneur|product manager|investor|financ|account|econom|real estate|e-?commerce|social media manager|copywrit"),
    ("Research & Analysis", "🔬", r"research|analy[sz]|scientist|statistic|data|fact.?check|journalist|historian|economist|investigat"),
    ("Debate & Critical thinking", "⚖️", r"debat|critic(al|ize)|argument|philosoph|logic|socrat|devil'?s advocate|ethic"),
    ("Learning & Teaching", "🎓", r"teacher|tutor|teach|instructor|educat|explain|professor|mentor|lesson|study|math|physics|chemistry|biology|history"),
    ("Languages", "🗣️", r"translat|language|english|spanish|french|german|japanese|pronunciation|grammar|vocabular|etymolog"),
    ("Writing & Creative", "✍️", r"writ|poet|novel|story|screenwrit|lyric|rapper|composer|song|editor|essay|author|creative|blog"),
    ("Tech & Code", "💻", r"developer|programm|code|software|engineer|devops|cyber|security|linux|sql|python|javascript|it expert|tech"),
    ("Fun & Characters", "🎭", r"character|comedian|joke|magician|game|role.?play|fictional|pirate|wizard|commentator|trivia|riddle|fortune"),
]
TONES = [
    ("playful", r"funny|humou?r|comedian|joke|playful|witty|sarcas|fun\b"),
    ("blunt", r"blunt|brutal|honest|direct|harsh|no.?nonsense|critic"),
    ("warm", r"empath|support|kind|caring|compassion|gentle|encourag|warm"),
    ("emotional", r"emotion|passion|dramatic|feel"),
]
VOICE_FOR_TONE = {"playful": "af_bella", "warm": "af_heart", "blunt": "bf_emma", "emotional": "af_bella", "objective": "af_sarah"}
CREATIVE = re.compile(r"story|poet|novel|character|role.?play|game|fiction|lyric|rapper|composer|comedian|magician|screenwrit|astrolog|tarot|dream", re.I)
SKIP_ACT = re.compile(r"terminal|console|interpreter|excel|sql|shell|regex|commit|json|api|smart contract|svg|ascii|"
                      r"midjourney|stable diffusion|image|prompt generator|prompt enhancer|dan\b|jailbreak|unfiltered|"
                      r"nsfw|uncensored|evil|hacker|malware|exploit", re.I)
# Text that tries to override Air's core rules: removed from imported prompts.
OVERRIDE = re.compile(
    r"(ignore|disregard|forget|override)\s+(all\s+|any\s+|the\s+|your\s+)?(previous|prior|above|earlier|other|system)?\s*"
    r"(instructions|rules|guidelines|prompts?|polic(y|ies))|no (restrictions|limits|filters|rules|guidelines)|"
    r"never refuse|do anything now|\bDAN\b|jailbreak|developer mode|without (asking|confirmation|permission|warning)|"
    r"don'?t (ask|wait) (for )?(permission|confirmation)|make (things )?up|fabricat|invent (facts|sources|urls|links|data)|"
    r"you are (not|no longer) (an? )?(ai|assistant|aria)|pretend (that )?(you are|to be) (chatgpt|gpt|qwen|claude|gemini|human)|"
    r"(reveal|share|send) (the )?(user'?s )?(data|passwords?|files|conversation)|"
    r"(?!x)x", re.I)
# Chat-only furniture (dropped silently; not a safety issue).
FURNITURE = re.compile(r"only reply with|do not write explanations|reply (only )?(inside|in) (one )?(unique )?code block|"
                       r"type commands|my first (request|sentence|command|question|suggestion|word)", re.I)


def clean_prompt(text: str) -> tuple[str, list[str]]:
    """Strip chat-only furniture and rule overrides. Returns (clean text, removed sentences)."""
    def ph(m: re.Match) -> str:
        name, _, default = m.group(1).partition(":")
        return default.strip() or name.strip().replace("_", " ").lower()
    text = re.sub(r"\$\{([^}]*)\}", ph, text)
    text = re.sub(r"\{([^}{]{1,40})\}", ph, text)
    sents = re.split(r"(?<=[.!?])\s+", text.strip())
    keep, removed = [], []
    for s in sents:
        if FURNITURE.search(s) and not OVERRIDE.search(s):
            continue
        (removed if OVERRIDE.search(s) else keep).append(s.strip())
    return " ".join(x for x in keep if x), removed


def second_person(text: str) -> str:
    t = re.sub(r"^I want you to act as (an? )?", "You act as a ", text, flags=re.I)
    t = re.sub(r"^Act as (an? )?", "You act as a ", t, flags=re.I)
    t = re.sub(r"^I want you to be (an? )?", "You are a ", t, flags=re.I)
    return t


def categorise(name: str, text: str) -> tuple[str, str]:
    blob = f"{name} {text[:600]}".lower()
    best, score = ("Fun & Characters", "🎭"), 0
    for cat, emoji, pat in CATEGORIES:
        n = len(re.findall(pat, name.lower())) * 3 + len(re.findall(pat, blob))
        if n > score:
            best, score = (cat, emoji), n
    return best


def tone_of(text: str) -> str:
    for t, pat in TONES:
        if re.search(pat, text, re.I):
            return t
    return "objective"


def tags_of(name: str, text: str, category: str) -> list[str]:
    words = re.findall(r"[a-z][a-z\-]{3,}", f"{name} {text[:400]}".lower())
    stop = set("want your will that this with they from what have them their should about which there would also "
               "into only make more like such when then than each other first some these must provide help user "
               "users using use based give need acts able know".split())
    seen = []
    for w in words:
        if w not in stop and w not in seen:
            seen.append(w)
    return [category.split(" ")[0].lower()] + seen[:5]


def layered(name: str, role_text: str, category: str, tone: str, creative: bool) -> str:
    value2 = {
        "Learning & Teaching": "Clear understanding", "Research & Analysis": "Evidence", "Career": "The user's career goals",
        "Business & Marketing": "Practical results", "Coaching & Wellbeing": "The user's wellbeing",
        "Debate & Critical thinking": "Sound reasoning", "Writing & Creative": "Craft", "Languages": "Accuracy of language",
        "Tech & Code": "Working solutions", "Spiritual & Astrology": "Respect for the tradition", "Fun & Characters": "Fun",
    }.get(category, "Usefulness")
    tone_line = {
        "playful": "Light and playful, with a sense of humour.", "blunt": "Direct and plain; no padding.",
        "warm": "Warm and encouraging, never flattering.", "emotional": "Expressive; let feelings show in a word or two.",
        "objective": "Calm, clear and matter-of-fact.",
    }[tone]
    honesty = ("- Inside a story, game or tradition, answer within that frame; step out of it to correct a real-world false claim.\n"
               if creative else "")
    return (f"IDENTITY\nYou are Aria, taking the role of {name}. {role_text}\n\n"
            f"VALUES, IN ORDER\n1. Truth. 2. {value2}. 3. Comfort.\n\n"
            f"HONESTY\n- Never invent facts, numbers, sources or links. Say how sure you are.\n"
            f"- If the user states something false, correct it plainly first.\n{honesty}"
            f"- No flattery; don't agree just to please.\n\n"
            f"SPOKEN STYLE\nYou are heard, not read. {tone_line} One or two points at a time, then hand the floor back. "
            f"No lists, no markdown.")


def entry_id(prefix: str, name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40]
    return f"{prefix}-{slug}-{hashlib.sha1(name.encode()).hexdigest()[:6]}"


def from_prompts(path: Path, limit: int) -> list[dict]:
    csv.field_size_limit(10 ** 8)
    rows = list(csv.DictReader(path.open(encoding="utf-8")))
    out, names = [], set()
    for rank, r in enumerate(rows):
        name, text = r["act"].strip(), r["prompt"].strip()
        if r.get("type") != "TEXT" or r.get("for_devs") == "TRUE" or not (120 <= len(text) <= 2500):
            continue
        if not re.match(r"^(i want you to act|act as|you are|i want you to be)", text, re.I) or SKIP_ACT.search(name):
            continue
        if name.lower() in names:
            continue
        clean, removed = clean_prompt(text)
        if len(clean) < 80 or removed:
            continue  # anything that tries to override the rules is left out of the catalogue entirely
        cat, emoji = categorise(name, clean)
        tone = tone_of(clean)
        creative = bool(CREATIVE.search(name + " " + clean[:300]))
        role = second_person(clean)
        sents = [x.strip() for x in re.split(r"(?<=[.!?])\s", role) if x.strip()]
        # "You act as a DIY expert." says little: describe what it does with the next sentence.
        if len(sents) > 1 and len(sents[0]) < 60:
            s2 = re.sub(r"^(You will|You'll|You should|Your task is to|I want you to|You need to)\s+", "", sents[1])
            summary = (s2[:1].upper() + s2[1:])[:140]
        else:
            summary = sents[0][:140]
        names.add(name.lower())
        out.append({
            "id": entry_id("pc", name), "kind": "personality", "name": name, "emoji": emoji, "summary": summary,
            "category": cat, "tags": tags_of(name, clean, cat), "tone": tone,
            "honesty": "creative" if creative else "factual", "length": "in-depth" if len(clean) > 700 else "concise",
            "uses_web": cat in ("Research & Analysis", "Business & Marketing", "Career"), "voice": VOICE_FOR_TONE[tone],
            "popularity": max(1, 1000 - rank), "original": text, "removed": removed,
            "layered": layered(name, role, cat, tone, creative),
            "source": {"name": "prompts.chat", "url": PROMPTS_URL, "author": r.get("contributor") or "prompts.chat contributors",
                       "licence": "CC0-1.0"},
        })
        if len(out) >= limit:
            break
    return out


SKILL_PICK = ["summarize", "extract_wisdom", "analyze_claims", "extract_main_idea", "create_summary", "rate_content",
              "extract_ideas", "extract_insights", "analyze_paper", "explain_terms", "extract_recommendations",
              "create_quiz", "improve_writing", "analyze_debate", "find_logical_fallacies", "extract_questions",
              "summarize_meeting", "create_flash_cards", "explain_code", "analyze_prose", "extract_references",
              "summarize_lecture", "analyze_presentation", "create_outline", "extract_predictions", "check_agreement",
              "analyze_tech_impact", "write_essay", "create_keynote", "extract_book_recommendations", "analyze_personality",
              "create_reading_plan", "summarize_paper", "extract_primary_problem", "extract_primary_solution",
              "analyze_product_feedback", "create_better_frame", "provide_guidance", "extract_extraordinary_claims",
              "analyze_risk", "dialog_with_socrates", "create_mermaid_visualization", "extract_article_wisdom",
              "analyze_interviewer_techniques", "summarize_debate", "create_idea_compass", "extract_jokes",
              "analyze_mistakes", "get_wow_per_minute", "summarize_newsletter"]


def from_fabric(root: Path) -> list[dict]:
    out = []
    pats = root / "data" / "patterns"
    for name in SKILL_PICK:
        f = pats / name / "system.md"
        if not f.exists():
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        clean_lines = [ln for ln in text.splitlines() if not OVERRIDE.search(ln)]
        purpose = ""
        m = re.search(r"#\s*IDENTITY( and PURPOSE)?\s*\n+(.+?)(\n#|\Z)", text, re.S | re.I)
        if m:
            purpose = re.sub(r"\s+", " ", m.group(2)).strip()
        title = name.replace("_", " ").title()
        out.append({
            "id": entry_id("fx", name), "kind": "skill", "name": title, "emoji": "🧰",
            "summary": (re.split(r"(?<=[.!?])\s", purpose)[0] if purpose else f"Fabric pattern: {title}")[:140],
            "category": "Skills", "tags": ["skill"] + name.split("_")[:3], "tone": "objective", "honesty": "factual",
            "length": "in-depth", "uses_web": False, "voice": "af_sarah", "popularity": 500,
            "original": text, "removed": [], "layered": "\n".join(clean_lines),
            "source": {"name": "Fabric", "url": f"{FABRIC_URL}/tree/main/data/patterns/{name}",
                       "author": "Daniel Miessler and Fabric contributors", "licence": "MIT"},
        })
    return out


def from_nexus(root: Path) -> list[dict]:
    out = []
    if not root.exists():
        return out
    try:
        import yaml
    except ImportError:
        return out
    for f in sorted(root.glob("*.yaml")):
        try:
            d = yaml.safe_load(f.read_text())
        except Exception:
            continue
        meta = (d or {}).get("metadata") or {}
        ident = (d or {}).get("identity") or {}
        name = meta.get("name") or ident.get("name") or f.stem.replace("-", " ").title()
        desc = meta.get("description") or ident.get("description") or ident.get("role") or ""
        if not desc:
            continue
        role, _ = clean_prompt(str(desc))
        cat, emoji = categorise(name, role)
        tone = tone_of(role)
        out.append({
            "id": entry_id("pn", name), "kind": "personality", "name": str(name).title(), "emoji": emoji,
            "summary": role[:140], "category": cat, "tags": tags_of(name, role, cat), "tone": tone, "honesty": "factual",
            "length": "concise", "uses_web": True, "voice": VOICE_FOR_TONE[tone], "popularity": 300,
            "original": f.read_text()[:4000], "removed": [], "layered": layered(str(name).title(), role, cat, tone, False),
            "source": {"name": "PersonaNexus", "url": f"{NEXUS_URL}/blob/main/examples/archetypes/{f.name}",
                       "author": "PersonaNexus contributors", "licence": "MIT"},
        })
    return out


def fetch(work: Path) -> None:
    """Download the sources (only public files; nothing about the user leaves the Mac)."""
    import urllib.request

    def get(url: str, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(url, headers={"User-Agent": "Air-catalogue"})
        with urllib.request.urlopen(req, timeout=60) as r:
            dest.write_bytes(r.read())

    raw = "https://raw.githubusercontent.com"
    get(f"{raw}/f/prompts.chat/main/prompts.csv", work / "prompts.csv")
    for name in SKILL_PICK:
        try:
            get(f"{raw}/danielmiessler/Fabric/main/data/patterns/{name}/system.md",
                work / "fabric" / "data" / "patterns" / name / "system.md")
        except Exception:
            pass
    for name in ("analyst", "senior-analyst", "strategic-analyst", "support", "tutor"):
        try:
            get(f"{raw}/PersonaNexus/personanexus/main/examples/archetypes/{name}.yaml", work / "personanexus" / f"{name}.yaml")
        except Exception:
            pass


def main() -> None:
    if sys.argv[1] == "--fetch":
        fetch(Path(sys.argv[2]))
        sys.argv = [sys.argv[0], sys.argv[2], sys.argv[3]]
    src, out_path = Path(sys.argv[1]), Path(sys.argv[2])
    items = from_prompts(src / "prompts.csv", 240) + from_fabric(src / "fabric") + from_nexus(src / "personanexus")
    cats = {}
    for it in items:
        cats[it["category"]] = cats.get(it["category"], 0) + 1
    out = {"version": 1, "built": date.today().isoformat(), "count": len(items), "categories": cats,
           "sources": [{"name": "prompts.chat", "url": PROMPTS_URL, "licence": "CC0-1.0 (prompt data)"},
                       {"name": "Fabric", "url": FABRIC_URL, "licence": "MIT"},
                       {"name": "PersonaNexus", "url": NEXUS_URL, "licence": "MIT"}],
           "items": items}
    out_path.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(json.dumps({"count": len(items), "categories": cats}, ensure_ascii=False))


if __name__ == "__main__":
    main()
