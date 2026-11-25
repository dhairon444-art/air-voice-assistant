"""Open-web search backends and Aria's research agent.

Search: DuckDuckGo's HTML results by default (no key), or the owner's SearXNG instance or a Brave
Search API key, set in Air's Settings (stored in ~/Library/Application Support/Air/search.json,
readable only by the owner). Wikipedia is one source among many.

Research: plan a few queries -> search them in parallel -> read 5-10 pages in parallel -> pick the
passages that answer the question (quotes with their URLs) -> hand them to the brain, which says
the answer, cites the domains and notes where sources disagree. "Deep research" reads more pages
and also writes a longer brief that can be saved with save_as.

Privacy: only search words and page URLs leave the Mac, never the conversation, Profile.md or
screenshots. Politeness: a page cap, at most two pages per site, short timeouts, no retries.
"""

from __future__ import annotations

import concurrent.futures as cf
import json
import re
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import quote, urlparse

CONFIG = Path.home() / "Library" / "Application Support" / "Air" / "search.json"

# Rough reputation by domain: used to order results, never to hide them.
REPUTABLE = {
    "wikipedia.org": 3, "reuters.com": 4, "apnews.com": 4, "bbc.co.uk": 4, "bbc.com": 4, "npr.org": 3,
    "theguardian.com": 3, "nytimes.com": 3, "washingtonpost.com": 3, "ft.com": 3, "economist.com": 3,
    "abc.net.au": 3, "aljazeera.com": 3, "bloomberg.com": 3, "cnbc.com": 2, "theverge.com": 2,
    "arstechnica.com": 3, "wired.com": 2, "nature.com": 4, "science.org": 4, "nih.gov": 4, "who.int": 4,
    "cdc.gov": 4, "nasa.gov": 4, "britannica.com": 3, "snopes.com": 3, "factcheck.org": 3,
    "politifact.com": 3, "fullfact.org": 3, "rtings.com": 3, "consumerreports.org": 3, "gsmarena.com": 2,
    "notebookcheck.net": 2, "anandtech.com": 3, "tomshardware.com": 2, "apple.com": 2, "github.com": 2,
    "arxiv.org": 3, "pubmed.ncbi.nlm.nih.gov": 4, "mayoclinic.org": 3, "investopedia.com": 2,
}
LOW = {"pinterest.com": -3, "quora.com": -1, "facebook.com": -3, "instagram.com": -3, "tiktok.com": -3,
       "x.com": -2, "twitter.com": -2, "medium.com": -1, "linkedin.com": -2}
STOP = set("""a an and are as at be by for from has have how i in is it its of on or that the this to was
what when where which who why will with you your does did do can could should would about into than then
there their them they we our me my more most much many any some tell latest news""".split())


def load_config() -> dict:
    try:
        return json.loads(CONFIG.read_text())
    except Exception:
        return {}


def domain(url: str) -> str:
    h = (urlparse(url).hostname or "").lower()
    return h[4:] if h.startswith("www.") else h


def reputation(url: str) -> int:
    d = domain(url)
    for table in (REPUTABLE, LOW):
        for k, v in table.items():
            if d == k or d.endswith("." + k):
                return v
    if d.endswith((".gov", ".gov.au", ".gov.uk", ".edu", ".ac.uk", ".edu.au", ".int")):
        return 3
    return 0


# ------------------------------------------------------------------ backends ---
def search(query: str, n: int = 8, timeout: float = 4.0) -> tuple[list[dict], str]:
    """Return ([{title, url, snippet}], backend name). Falls back to DuckDuckGo."""
    from web_tools import _get, ddg_search

    cfg = load_config()
    backend = cfg.get("backend", "duckduckgo")
    try:
        if backend == "searxng" and cfg.get("searxng_url"):
            base = cfg["searxng_url"].rstrip("/")
            r = _get(f"{base}/search?format=json&q={quote(query)}", timeout)
            r.raise_for_status()
            res = [{"title": x.get("title", ""), "url": x.get("url", ""), "snippet": x.get("content", "")}
                   for x in r.json().get("results", []) if x.get("url", "").startswith("http")]
            return res[:n], "SearXNG"
        if backend == "brave" and cfg.get("brave_key"):
            import requests

            r = requests.get("https://api.search.brave.com/res/v1/web/search",
                             params={"q": query, "count": min(n, 20)}, timeout=timeout,
                             headers={"Accept": "application/json", "X-Subscription-Token": cfg["brave_key"]})
            r.raise_for_status()
            res = [{"title": x.get("title", ""), "url": x.get("url", ""),
                    "snippet": re.sub(r"<[^>]+>", "", x.get("description", ""))}
                   for x in r.json().get("web", {}).get("results", [])]
            return res[:n], "Brave"
    except Exception:
        pass  # fall back to the no-key default
    return ddg_search(query, timeout, n=n), "DuckDuckGo"


# ------------------------------------------------------------------ passages ---
def _terms(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9][a-z0-9\-\.]+", text.lower()) if len(w) > 2 and w not in STOP}


def best_passages(text: str, question_terms: set[str], k: int = 3, max_len: int = 280) -> list[str]:
    sents = re.split(r"(?<=[.!?])\s+(?=[A-Z0-9\"'(])", re.sub(r"\s+", " ", text))
    scored = []
    for i, s in enumerate(sents):
        s = re.sub(r"\[(\d+|citation needed|note \d+)\]", "", s).strip()
        if not 40 <= len(s) <= 600:
            continue
        if re.search(r"Retrieved|\u2191|ISBN|doi:|Archived from|^\(\d{4}\)|Cookie|cookies|Subscribe|Sign up", s):
            continue  # references, footnotes and page furniture
        if s.startswith(("\"", "\u201c")) and len(s) < 140 and s.rstrip(".").endswith(("\"", "\u201d", "?\"")):
            continue  # a bare quoted title
        overlap = len(_terms(s) & question_terms)
        if not overlap:
            continue
        score = overlap + (0.5 if re.search(r"\d", s) else 0) - i * 0.002
        scored.append((score, i, s))
    top = sorted(scored, reverse=True)[:k]
    return [s[:max_len] + ("..." if len(s) > max_len else "") for _, _, s in sorted(top, key=lambda t: t[1])]


# ------------------------------------------------------------------ the agent ---
class Researcher:
    """Runs on the GPU thread (inside a tool call), so it may call the brain directly via `llm`."""

    def __init__(self, web, llm, progress, cancelled):
        self.web = web              # WebSession (offline check, source log, save_as)
        self.llm = llm              # callable(messages, max_tokens) -> str
        self.progress = progress    # callable(step, text)
        self.cancelled = cancelled  # callable() -> bool

    def plan(self, question: str, count: int) -> list[str]:
        today = datetime.now().strftime("%d %B %Y")
        try:
            out = self.llm([
                {"role": "system", "content": "You write web search queries. Output only the queries, one per line, no numbering."},
                {"role": "user", "content": f"Today is {today}. Write {count} different short web search queries "
                                            f"to research this question well. Include one that looks for "
                                            f"criticism, disagreement or fact-checks, and one aimed at the newest "
                                            f"information if timing matters.\nQuestion: {question}"},
            ], 90)
        except Exception:
            out = ""
        qs = []
        for line in out.splitlines():
            line = re.sub(r"^[\s\-\*\d\.\)\"]+|\"$", "", line).strip()
            if 3 <= len(line) <= 120 and line.lower() not in (x.lower() for x in qs):
                qs.append(line)
        return ([question[:120]] + [q for q in qs if q.lower() != question.lower()])[:count + 1]

    def run(self, question: str, deep: bool = False) -> dict:
        if not self.web.net.online:
            return {"ok": False, "offline": True,
                    "error": "Research needs the internet, and the Mac is offline right now."}
        t0 = time.time()
        max_pages = 10 if deep else 6
        read_budget = 25.0 if deep else 12.0
        qterms = _terms(question)

        self.progress("plan", "Planning the searches")
        queries = self.plan(question, 4 if deep else 2)
        if self.cancelled():
            return {"ok": False, "error": "Research stopped."}
        self.progress("search", f"Searching: {'; '.join(queries)}")

        found: dict[str, dict] = {}
        backend = "DuckDuckGo"
        with cf.ThreadPoolExecutor(len(queries) + 1) as ex:
            futs = {ex.submit(search, q, 8): q for q in queries}
            from web_tools import wikipedia_summary
            wiki_f = ex.submit(wikipedia_summary, question, 4.0)
            for f in cf.as_completed(list(futs) + [wiki_f], timeout=8):
                try:
                    res = f.result()
                except Exception:
                    continue
                if f is wiki_f:
                    if res and res.get("url"):
                        found.setdefault(res["url"], {"title": "Wikipedia: " + res["title"], "url": res["url"],
                                                      "snippet": res.get("extract", ""), "score": 2.5})
                    continue
                items, backend = res
                for rank, r in enumerate(items):
                    u = r["url"].split("#")[0]
                    score = reputation(u) + 2.0 / (rank + 1) + 0.3 * len(_terms(r["title"] + " " + r["snippet"]) & qterms)
                    if u in found:
                        found[u]["score"] += 1.0  # found by several queries
                    else:
                        found[u] = {**r, "url": u, "score": score}
        ranked = sorted(found.values(), key=lambda r: -r["score"])
        if not ranked:
            return {"ok": False, "error": "The searches came back empty. I can answer from what I know, unverified."}

        per_site: dict[str, int] = {}
        picks = []
        for r in ranked:
            d = domain(r["url"])
            if per_site.get(d, 0) >= 2 or r["url"].lower().endswith((".pdf", ".zip", ".mp4")):
                continue
            per_site[d] = per_site.get(d, 0) + 1
            picks.append(r)
            if len(picks) >= max_pages:
                break
        if self.cancelled():
            return {"ok": False, "error": "Research stopped."}
        self.progress("read", f"Reading {len(picks)} pages: " + ", ".join(domain(p["url"]) for p in picks))

        pages = []
        t_read = time.time()
        with cf.ThreadPoolExecutor(min(8, len(picks))) as ex:
            futs = {ex.submit(self._read, p["url"]): p for p in picks}
            try:
                for f in cf.as_completed(futs, timeout=read_budget):
                    p = futs[f]
                    try:
                        text, final, title = f.result()
                    except Exception:
                        text, final, title = "", p["url"], p["title"]
                    quotes = best_passages(text, qterms) if text else []
                    if not quotes and p.get("snippet"):
                        quotes = [p["snippet"][:280]]  # the page didn't load: keep the search snippet
                    if quotes:
                        pages.append({"url": final, "domain": domain(final), "title": title or p["title"],
                                      "quotes": quotes, "score": p["score"], "read": bool(text)})
                    if self.cancelled():
                        break
            except cf.TimeoutError:
                pass  # use what came back within the time budget
        if self.cancelled():
            return {"ok": False, "error": "Research stopped."}
        pages.sort(key=lambda p: -p["score"])
        read_s = time.time() - t_read

        for i, p in enumerate(pages, 1):
            p["n"] = i
        self.web.last_sources = [{"title": p["title"], "url": p["url"]} for p in pages]
        for p in pages:
            self.web._note("researched" if p["read"] else "search result", p["url"], p["title"])

        brief = ""
        if deep and pages:
            self.progress("write", "Writing the brief")
            brief = self.write_brief(question, pages)

        took = time.time() - t0
        self.progress("done", f"{len(pages)} sources in {took:.0f} s")
        record = {"question": question, "deep": deep, "seconds": round(took, 1), "read_s": round(read_s, 1),
                  "queries": queries, "backend": backend, "pages": pages, "brief": brief}
        self.web.last_research = record
        self.web.last_extract = {"kind": "text", "title": f"Research: {question[:60]}", "url": "",
                                 "text": brief_markdown(record), "tables": []}

        # What goes back to the brain: numbered quotes, kept within the tool-message budget.
        compact, size = [], 0
        for p in pages:
            item = {"n": p["n"], "site": p["domain"], "quotes": p["quotes"][:2 if size > 2200 else 3]}
            size += len(json.dumps(item))
            if size > 3300:
                break
            compact.append(item)
        out = {"ok": True, "summary": f"Researched {len(pages)} sources ({', '.join(p['domain'] for p in pages[:6])}) in {took:.0f} s",
               "sources": compact,
               "note": (f"Today is {datetime.now().strftime('%d %B %Y')}. These sources are current and may describe events "
                        "after your training data: when they conflict with what you remember, trust the sources, never "
                        "claim something hasn't happened yet. "
                        "Answer the question from these quotes in a few spoken sentences. Name the sites you rely on. "
                        "If sources disagree or a claim is only in one weak source, say so. Say how sure you are. "
                        "Do not invent anything the quotes don't say.")}
        if brief:
            out["brief"] = brief[:1500]
            out["note"] += " A written brief was prepared; offer to save it (save_as, e.g. Word or a note)."
        return out

    def _read(self, url: str) -> tuple[str, str, str]:
        import trafilatura

        html, final = self.web._fetch(url)
        text = trafilatura.extract(html, include_comments=False, include_tables=False, favor_precision=True) or ""
        meta = trafilatura.extract_metadata(html)
        return text[:60000], final, (meta.title if meta and meta.title else "")

    def write_brief(self, question: str, pages: list[dict]) -> str:
        src = "\n".join(f"[{p['n']}] {p['domain']}: " + " | ".join(p["quotes"]) for p in pages)[:6000]
        try:
            return self.llm([
                {"role": "system", "content": "You write short, accurate research briefs from the quotes given. "
                                              "Use only what the quotes say. Cite every claim like [2]."},
                {"role": "user", "content": f"Question: {question}\n\nQuotes:\n{src}\n\nWrite a brief with these parts: "
                                            "Answer (2-3 sentences). Key findings (3-6 bullets, each cited). "
                                            "Where sources disagree (or 'No real disagreement found'). "
                                            "How sure (one line)."},
            ], 520).strip()
        except Exception as exc:
            return f"(The brief couldn't be written: {exc})"


def brief_markdown(r: dict) -> str:
    lines = [f"Question: {r['question']}", "",
             f"{'Deep research' if r['deep'] else 'Research'} on {datetime.now().strftime('%d %b %Y %H:%M')}, "
             f"{len(r['pages'])} sources in {r['seconds']} s via {r['backend']}.", ""]
    if r.get("brief"):
        lines += [r["brief"], ""]
    lines += ["Sources and quotes:", ""]
    for p in r["pages"]:
        title = p["title"].replace("[", "(").replace("]", ")")
        lines.append(f"[{p['n']}] [{title}]({p['url']}) ({p['domain']})")
        for q in p["quotes"]:
            lines.append(f'    - "{q}"')
    return "\n".join(lines)
