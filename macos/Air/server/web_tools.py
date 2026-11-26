"""Aria's online tools: fact-check search, browser (open/read pages), extraction of page content
and video transcripts, and saving results as Excel, Word, CSV or a Markdown note.

Privacy: only the search query or the URL leaves the Mac (never the conversation, the profile or
screenshots). A generic browser User-Agent is used. Public content only: no logins, forms,
purchases, posting, paywall or protection bypassing. Air works fully offline; every tool here
fails fast and politely when the Mac is offline.
"""

from __future__ import annotations

import concurrent.futures as cf
import io
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlparse

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
EXPORTS = Path.home() / "Documents" / "Air Exports"
SEARCH_BUDGET_S = 1.5


class Connectivity:
    """Cached online/offline state, refreshed in the background so turns never wait on it."""

    def __init__(self, interval: float = 15.0):
        self.online = False
        self.checked = 0.0
        self.interval = interval
        threading.Thread(target=self._loop, name="air-net", daemon=True).start()

    def probe(self) -> bool:
        for host, port in (("1.1.1.1", 443), ("8.8.8.8", 53)):
            try:
                with socket.create_connection((host, port), timeout=0.5):
                    return True
            except OSError:
                continue
        return False

    def _loop(self) -> None:
        while True:
            self.online = self.probe()
            self.checked = time.time()
            time.sleep(self.interval)


def _get(url: str, timeout: float, **kw):
    import requests

    return requests.get(url, timeout=timeout, headers={"User-Agent": UA, "Accept-Language": "en"}, **kw)


def _clean_url(href: str) -> str:
    if href.startswith("//"):
        href = "https:" + href
    q = parse_qs(urlparse(href).query)
    if "uddg" in q:  # DuckDuckGo redirect
        return unquote(q["uddg"][0])
    return href


def ddg_search(query: str, timeout: float, n: int = 5) -> list[dict]:
    import requests
    from lxml import html as lh

    r = requests.post("https://html.duckduckgo.com/html/", data={"q": query}, timeout=timeout,
                      headers={"User-Agent": UA, "Accept-Language": "en"})
    doc = lh.fromstring(r.text)
    out = []
    for res in doc.xpath('//div[contains(concat(" ", normalize-space(@class), " "), " result ")]'):
        a = res.xpath('.//a[contains(@class, "result__a")]')
        if not a:
            continue
        url = _clean_url(a[0].get("href", ""))
        if "duckduckgo.com/y.js" in url or not url.startswith("http"):
            continue  # ads
        snip = res.xpath('.//*[contains(@class, "result__snippet")]')
        out.append({"title": a[0].text_content().strip(), "url": url,
                    "snippet": snip[0].text_content().strip() if snip else ""})
        if len(out) >= n:
            break
    return out


def wikipedia_summary(query: str, timeout: float) -> dict | None:
    r = _get("https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=1&srsearch="
             + quote(query), timeout)
    hits = r.json().get("query", {}).get("search", [])
    if not hits:
        return None
    title = hits[0]["title"]
    s = _get("https://en.wikipedia.org/api/rest_v1/page/summary/" + quote(title.replace(" ", "_")), timeout).json()
    return {"title": s.get("title", title), "extract": s.get("extract", ""),
            "url": s.get("content_urls", {}).get("desktop", {}).get("page", "https://en.wikipedia.org/wiki/" + quote(title))}


def _is_youtube(url: str) -> str | None:
    u = urlparse(url)
    if u.hostname and ("youtube.com" in u.hostname or "youtu.be" in u.hostname):
        if "youtu.be" in u.hostname:
            return u.path.strip("/").split("/")[0] or None
        if u.path.startswith(("/shorts/", "/live/", "/embed/")):
            return u.path.split("/")[2]
        return parse_qs(u.query).get("v", [None])[0]
    return None


def _unique(path: Path) -> Path:
    if not path.exists():
        return path
    n = 2
    while True:
        p = path.with_name(f"{path.stem} ({n}){path.suffix}")
        if not p.exists():
            return p
        n += 1


def _safe_name(s: str) -> str:
    s = re.sub(r"[\\/:*?\"<>|\n\r\t]+", " ", s).strip()
    return re.sub(r"\s+", " ", s)[:80] or "Air export"


class WebSession:
    """Per-conversation state: last sources (for "open that source"), the last extraction (for
    save_as), and a log of every URL searched, opened or read (for the session note)."""

    def __init__(self, net: Connectivity, vault: Path, transcribe_audio=None):
        self.net = net
        self.vault = vault
        self.transcribe_audio = transcribe_audio  # callable(wav_path) -> list[(start, text)]
        self.last_sources: list[dict] = []
        self.last_extract: dict | None = None
        self.log: list[dict] = []
        self.last_results: list[dict] = []
        self.last_research: dict | None = None

    # -------------------------------------------------------------- helpers ---
    def _note(self, action: str, url: str, title: str = "") -> None:
        self.log.append({"time": time.strftime("%H:%M:%S"), "action": action, "url": url, "title": title})

    def _offline(self) -> dict | None:
        if not self.net.online:
            return {"ok": False, "offline": True, "error": "The Mac is offline, so I can't reach the web right now."}
        return None

    # ---------------------------------------------------------------- tools ---
    def web_search(self, query: str) -> dict:
        if (o := self._offline()):
            return o
        t0 = time.time()
        results, wiki = [], None
        from research import reputation, search as backend_search

        with cf.ThreadPoolExecutor(2) as ex:
            f1 = ex.submit(lambda: backend_search(query, 8, SEARCH_BUDGET_S)[0])
            f2 = ex.submit(wikipedia_summary, query, SEARCH_BUDGET_S)
            done, _ = cf.wait([f1, f2], timeout=SEARCH_BUDGET_S + 0.1)
            if f1 in done and not f1.exception():
                results = f1.result()
            if f2 in done and not f2.exception():
                wiki = f2.result()
        ms = (time.time() - t0) * 1000
        if not results and not wiki:
            return {"ok": False, "error": f"The search didn't come back in time ({ms:.0f} ms). Answer from your own knowledge and say you couldn't verify it online."}
        # Reputable sites first (stable within the same reputation); Wikipedia is one source among many.
        results = sorted(results, key=lambda r_: -reputation(r_["url"]))
        if wiki:
            results = [r_ for r_ in results if r_["url"] != wiki["url"]]
        sources = [{"title": r["title"], "url": r["url"]} for r in results[:2]] + \
                  ([{"title": "Wikipedia: " + wiki["title"], "url": wiki["url"]}] if wiki else []) + \
                  [{"title": r["title"], "url": r["url"]} for r in results[2:]]
        self.last_results = results
        self.last_sources = sources
        self._note("searched", "https://duckduckgo.com/?q=" + quote(query), query)
        for s in sources[:3]:
            self._note("source", s["url"], s["title"])
        # Keep what goes back into the prompt small: it is re-read before the spoken answer.
        compact = []
        for s_ in sources[:5]:
            if wiki and s_["url"] == wiki["url"]:
                compact.append({"n": len(compact) + 1, "site": "wikipedia.org", "text": wiki["extract"][:450]})
            else:
                r_ = next(x for x in results if x["url"] == s_["url"])
                compact.append({"n": len(compact) + 1, "site": (urlparse(r_["url"]).hostname or "").removeprefix("www."),
                                "text": r_["snippet"][:220]})
        return {"ok": True, "summary": f"{len(sources)} sources in {ms:.0f} ms", "sources": compact,
                "note": (f"Today is {datetime.now().strftime('%d %B %Y')}; these results are current and may be newer than "
                         "your training data, so trust them over memory. Answer from these; say briefly what it's based on.")}

    def open_url(self, url: str) -> dict:
        if not re.match(r"^https?://", url or ""):
            return {"ok": False, "error": "I can only open web links (http or https)."}
        if (o := self._offline()):
            return o
        subprocess.run(["/usr/bin/open", url], check=False, timeout=10)
        self._note("opened", url)
        return {"ok": True, "summary": f"Opened {urlparse(url).hostname} in your browser"}

    def web_search_and_open(self, query: str) -> dict:
        r = self.web_search(query)
        if not r.get("ok"):
            return r
        best = (getattr(self, "last_results", None) or self.last_sources or [{}])[0]
        if not best.get("url"):
            return {"ok": False, "error": "No result to open."}
        o = self.open_url(best["url"])
        o["opened"] = best
        return o

    def open_source(self, number: int = 1) -> dict:
        if not self.last_sources:
            return {"ok": False, "error": "There are no sources from the last answer to open."}
        i = max(1, int(number)) - 1
        if i >= len(self.last_sources):
            return {"ok": False, "error": f"There are only {len(self.last_sources)} sources."}
        return self.open_url(self.last_sources[i]["url"])

    # ---- several sites at once (each in a new tab, in order; at most max_tabs per request) ----
    @staticmethod
    def _site(url: str) -> str:
        h = (urlparse(url).hostname or url).removeprefix("www.")
        return h

    def _open_many(self, urls: list[str]) -> dict:
        urls = [u for u in urls if u][:getattr(self, "max_tabs", 15)]
        bad = [u for u in urls if not re.match(r"^https?://", u)]
        if bad:
            return {"ok": False, "error": f"I can only open web links (http or https), not {bad[0]}."}
        if (o := self._offline()):
            return o
        for i, u in enumerate(urls):
            subprocess.run(["/usr/bin/open", u], check=False, timeout=10)
            self._note("opened", u)
            if i < len(urls) - 1:
                time.sleep(0.35)   # keeps the tabs in the order asked
        sites = [self._site(u) for u in urls]
        return {"ok": True, "opened": urls, "summary": f"Opened {len(urls)} tab{'s' if len(urls) != 1 else ''}: " + ", ".join(sites),
                "note": "Say one short line, for example: 'Opened " + str(len(urls)) + " tabs: " + ", ".join(sites) + ".'"}

    def multi(self, name: str, a: dict) -> dict:
        """open_url / web_search_and_open / open_source / read_page with one item or a list."""
        if name == "open_url":
            return self._open_many(list(a.get("urls") or []) + ([a["url"]] if a.get("url") else []))
        if name == "open_source":
            if not self.last_sources:
                return {"ok": False, "error": "There are no sources from the last answer to open."}
            nums = list(range(1, len(self.last_sources) + 1)) if a.get("all") else \
                [int(n) for n in (a.get("numbers") or []) + ([a["number"]] if a.get("number") else [])] or [1]
            missing = [n for n in nums if not 1 <= n <= len(self.last_sources)]
            if missing:
                return {"ok": False, "error": f"There are only {len(self.last_sources)} sources."}
            return self._open_many([self.last_sources[n - 1]["url"] for n in nums])
        if name == "web_search_and_open":
            queries = [q for q in (a.get("queries") or []) + ([a["query"]] if a.get("query") else []) if q]
            if not queries:
                return {"ok": False, "error": "Tell me what to open."}
            cap = getattr(self, "max_tabs", 15)
            count = max(1, min(cap, int(a.get("count") or 1)))
            urls = []
            if len(queries) == 1 and count > 1:
                r = self.web_search(queries[0])
                if not r.get("ok"):
                    return r
                urls = [x["url"] for x in (getattr(self, "last_results", None) or self.last_sources or [])][:count]
            else:
                for q in queries[:cap]:
                    r = self.web_search(q)
                    if not r.get("ok"):
                        return r
                    best = (getattr(self, "last_results", None) or self.last_sources or [{}])[0]
                    if best.get("url") and self._site(best["url"]) not in {self._site(u) for u in urls}:
                        urls.append(best["url"])   # one tab per site
            if not urls:
                return {"ok": False, "error": "No results to open."}
            return self._open_many(urls)
        if name == "read_page":
            urls = [u for u in (a.get("urls") or []) + ([a["url"]] if a.get("url") else []) if u][:getattr(self, "max_tabs", 15)]
            if len(urls) <= 1:
                return self.read_page(urls[0] if urls else "")
            each = max(1200, 7000 // len(urls))
            pages, read = [], []
            for u in urls:
                r = self.read_page(u, max_chars=each)
                pages.append({k: r.get(k) for k in ("ok", "title", "url", "text", "error")})
                if r.get("ok"):
                    read.append({"title": r["title"], "url": r["url"]})
            self.last_sources = read
            return {"ok": bool(read), "summary": f"Read {len(read)} of {len(urls)} pages", "pages": pages}
        return {"ok": False, "error": f"unknown tool {name}"}

    def _fetch(self, url: str) -> tuple[str, str]:
        r = _get(url, timeout=8)
        r.raise_for_status()
        ctype = r.headers.get("content-type", "")
        if "html" not in ctype and "xml" not in ctype and "text" not in ctype:
            raise ValueError(f"That link isn't a web page ({ctype.split(';')[0] or 'unknown type'}).")
        return r.text, r.url

    def read_page(self, url: str, max_chars: int = 3500) -> dict:
        if (o := self._offline()):
            return o
        import trafilatura

        try:
            html, final = self._fetch(url)
        except Exception as exc:
            return {"ok": False, "error": f"I couldn't load that page: {exc}"}
        text = trafilatura.extract(html, include_comments=False, include_tables=True, favor_recall=True) or ""
        meta = trafilatura.extract_metadata(html)
        title = (meta.title if meta and meta.title else urlparse(final).hostname) or final
        if not text.strip():
            return {"ok": False, "error": "The page has no readable text without JavaScript, or it's behind a login."}
        self._note("read", final, title)
        self.last_sources = [{"title": title, "url": final}]
        self.last_extract = {"kind": "page", "title": title, "url": final, "text": text, "tables": [], "links": []}
        return {"ok": True, "summary": f"Read '{title}' ({len(text)} characters)", "title": title, "url": final,
                "text": text[:max_chars], "truncated": len(text) > max_chars}

    def extract_page(self, url: str) -> dict:
        if (o := self._offline()):
            return o
        import pandas as pd
        import trafilatura
        from lxml import html as lh

        try:
            html, final = self._fetch(url)
        except Exception as exc:
            return {"ok": False, "error": f"I couldn't load that page: {exc}"}
        text = trafilatura.extract(html, include_tables=False, favor_recall=True) or ""
        meta = trafilatura.extract_metadata(html)
        title = (meta.title if meta and meta.title else urlparse(final).hostname) or final
        tables = []
        try:
            frames = pd.read_html(io.StringIO(html))[:12]
        except Exception:
            frames = []
        for df in frames:
            try:
                df = df.dropna(how="all").dropna(axis=1, how="all")
                if df.shape[0] < 3 or df.shape[1] < 2:
                    continue  # legends and keys, not data
                cols = []
                for i, c in enumerate(df.columns):
                    parts = c if isinstance(c, tuple) else (c,)
                    seen = []
                    for x in parts:
                        x = re.sub(r"\[[^\]]*\]", "", str(x)).strip()  # footnote markers like [14]
                        if x and "Unnamed" not in x and x.lower() != "nan" and x not in seen:
                            seen.append(x)
                    name = " ".join(seen) or ("#" if i == 0 else f"Column {i + 1}")
                    while name in cols:
                        name += " (2)"
                    cols.append(name)
                def cell(v):
                    if isinstance(v, float):
                        if v != v:
                            return ""
                        if v.is_integer():
                            return str(int(v))
                    return re.sub(r"\[[^\]]*\]", "", str(v)).strip()
                rows = [[cell(v) for v in r] for r in df.head(500).values.tolist()]
                tables.append({"columns": cols, "rows": rows})
            except Exception as exc:
                self.table_errors = getattr(self, "table_errors", []) + [repr(exc)]
        tables = sorted(tables, key=lambda t: -len(t["rows"]))[:8]
        links = []
        try:
            doc = lh.fromstring(html)
            doc.make_links_absolute(final)
            for a in doc.xpath("//a[@href]"):
                t = a.text_content().strip()
                h = a.get("href")
                if t and h.startswith("http") and len(t) > 2:
                    links.append({"text": t[:120], "url": h})
                if len(links) >= 60:
                    break
        except Exception:
            pass
        prices = sorted(set(re.findall(r"(?:[$€£]|AUD|USD|EUR)\s?\d[\d,]*(?:\.\d{2})?", text)))[:30]
        dates = sorted(set(re.findall(r"\b\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{4}\b|\b\d{4}-\d{2}-\d{2}\b", text)))[:30]
        self._note("extracted", final, title)
        self.last_sources = [{"title": title, "url": final}]
        self.last_extract = {"kind": "page", "title": title, "url": final, "text": text, "tables": tables,
                             "links": links, "prices": prices, "dates": dates}
        preview = [{"columns": t["columns"], "first_rows": t["rows"][:3], "row_count": len(t["rows"])} for t in tables]
        return {"ok": True, "summary": f"Extracted '{title}': {len(tables)} tables, {len(links)} links, {len(text)} characters",
                "title": title, "url": final, "tables": preview, "prices": prices[:10], "dates": dates[:10],
                "text_start": text[:600], "note": "The full extraction is kept; use save_as to write it to a file."}

    def get_video_transcript(self, url: str) -> dict:
        if (o := self._offline()):
            return o
        title, segs, duration = url, [], None
        vid = _is_youtube(url)
        try:
            import yt_dlp

            with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True, "no_warnings": True}) as y:
                info = y.extract_info(url, download=False)
            title = info.get("title") or url
            duration = info.get("duration")
        except Exception:
            info = None
        if vid:
            try:
                from youtube_transcript_api import YouTubeTranscriptApi

                fetched = YouTubeTranscriptApi().fetch(vid, languages=["en", "en-US", "en-GB"])
                segs = [(float(s.start), s.text.replace("\n", " ")) for s in fetched]
            except Exception:
                segs = []
        if not segs and info:
            segs = self._yt_dlp_captions(info)
        if not segs:
            mins = round((duration or 0) / 60, 1)
            est = max(1, round((duration or 600) * 0.03 + 20))
            return {"ok": False, "no_captions": True, "title": title, "duration_minutes": mins,
                    "error": f"That video has no captions. I can transcribe its audio here on the Mac "
                             f"(temporary audio, deleted afterwards); for a {mins}-minute video that takes about {est} seconds."}
        text = " ".join(t for _, t in segs)
        self._note("transcript", url, title)
        self.last_sources = [{"title": title, "url": url}]
        self.last_extract = {"kind": "transcript", "title": title, "url": url, "segments": segs, "text": text}
        return {"ok": True, "summary": f"Transcript of '{title}': {len(segs)} lines, {len(text.split())} words",
                "title": title, "text_start": text[:2000], "note": "Use save_as to write it to a file."}

    def _yt_dlp_captions(self, info: dict) -> list:
        import requests

        for kind in ("subtitles", "automatic_captions"):
            subs = info.get(kind) or {}
            for lang in ("en", "en-US", "en-GB", "en-orig"):
                for fmt in subs.get(lang) or []:
                    if fmt.get("ext") == "vtt":
                        try:
                            vtt = requests.get(fmt["url"], timeout=10, headers={"User-Agent": UA}).text
                            return _parse_vtt(vtt)
                        except Exception:
                            pass
        return []

    def transcribe_video_audio(self, url: str) -> dict:
        """Only after the user agreed: temporary audio download, local Parakeet, files deleted."""
        if (o := self._offline()):
            return o
        if self.transcribe_audio is None or not shutil.which("ffmpeg", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin"):
            return {"ok": False, "error": "Local transcription needs ffmpeg, which isn't installed."}
        import yt_dlp

        tmp = Path(tempfile.mkdtemp(prefix="air-audio-"))
        try:
            opts = {"quiet": True, "no_warnings": True, "noprogress": True, "format": "bestaudio/best",
                    "outtmpl": str(tmp / "audio.%(ext)s"), "max_filesize": 400 * 1024 * 1024}
            with yt_dlp.YoutubeDL(opts) as y:
                info = y.extract_info(url, download=True)
            src = next(tmp.glob("audio.*"))
            wav = tmp / "audio16k.wav"
            ff = shutil.which("ffmpeg", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin")
            subprocess.run([ff, "-loglevel", "error", "-i", str(src), "-ac", "1", "-ar", "16000", str(wav)],
                           check=True, timeout=600)
            t0 = time.time()
            segs = self.transcribe_audio(str(wav))
            title = info.get("title") or url
            text = " ".join(t for _, t in segs)
            self._note("transcribed audio", url, title)
            self.last_extract = {"kind": "transcript", "title": title, "url": url, "segments": segs, "text": text}
            return {"ok": True, "summary": f"Transcribed '{title}' here in {time.time() - t0:.0f}s ({len(text.split())} words); the audio was deleted",
                    "text_start": text[:2000]}
        except Exception as exc:
            return {"ok": False, "error": f"I couldn't transcribe it: {exc}"}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def save_as(self, fmt: str, title: str | None = None, content: str | None = None) -> dict:
        """Write the last extraction (or given text) to xlsx/docx/csv in ~/Documents/Air Exports,
        or a Markdown note in the Air vault. Never overwrites: adds ' (2)', ' (3)'..."""
        fmt = (fmt or "").lower().strip(". ")
        fmt = {"excel": "xlsx", "word": "docx", "markdown": "md", "note": "md", "obsidian": "md",
               "spreadsheet": "xlsx", "document": "docx"}.get(fmt, fmt)
        if fmt not in ("xlsx", "docx", "csv", "md"):
            return {"ok": False, "error": "Which format: Excel, Word, CSV, or a note in your Air vault?"}
        data = self.last_extract
        if content and (not data or len(content) > 20 and fmt in ("docx", "md") and data.get("kind") != "transcript"):
            data = {"kind": "text", "title": title or "Notes from Aria", "url": "", "text": content, "tables": []}
        if not data:
            return {"ok": False, "error": "There's nothing extracted yet to save. Ask me to get a transcript or pull a page first."}
        name = _safe_name(title or data.get("title") or "Air export")
        stamp = datetime.now().strftime("%Y-%m-%d")
        if fmt == "md":
            folder = self.vault / "Exports"
            folder.mkdir(parents=True, exist_ok=True)
            path = _unique(folder / f"{name}.md")
            path.write_text(_to_markdown(data, name), encoding="utf-8")
        else:
            EXPORTS.mkdir(parents=True, exist_ok=True)
            path = _unique(EXPORTS / f"{name} {stamp}.{fmt}")
            {"xlsx": _to_xlsx, "docx": _to_docx, "csv": _to_csv}[fmt](data, path, name)
        self._note("saved", str(path), name)
        return {"ok": True, "summary": f"Saved {path.name}", "path": str(path),
                "note": "Offer to open it (open_file with this path)."}


# ------------------------------------------------------------------ writers ---

def _parse_vtt(vtt: str) -> list:
    out, last = [], ""
    for block in vtt.split("\n\n"):
        m = re.search(r"(\d+):(\d\d):(\d\d)\.(\d+) -->", block)
        if not m:
            continue
        start = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        lines = [re.sub(r"<[^>]+>", "", l).strip() for l in block.split("\n")[1:] if "-->" not in l]
        text = " ".join(l for l in lines if l)
        if text and text != last:
            out.append((float(start), text))
            last = text
    return out


def _ts(sec: float) -> str:
    sec = int(sec)
    h, r = divmod(sec, 3600)
    m, s = divmod(r, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def _paragraphs(segs: list, every: float = 60.0) -> list[tuple[float, str]]:
    paras, cur, start = [], [], None
    for t, text in segs:
        if start is None:
            start = t
        cur.append(text)
        if t - start >= every:
            paras.append((start, " ".join(cur)))
            cur, start = [], None
    if cur:
        paras.append((start or 0.0, " ".join(cur)))
    return paras


def _to_xlsx(data: dict, path: Path, name: str) -> None:
    from openpyxl import Workbook
    from openpyxl.styles import Font

    wb = Workbook()
    ws = wb.active
    bold = Font(bold=True)
    if data["kind"] == "transcript":
        ws.title = "Transcript"
        ws.append(["Start", "Seconds", "Text"])
        for t, text in data["segments"]:
            ws.append([_ts(t), round(t, 1), text])
        ws.column_dimensions["C"].width = 100
    elif data.get("tables"):
        wb.remove(ws)
        for i, t in enumerate(data["tables"], 1):
            sh = wb.create_sheet(f"Table {i}")
            sh.append(t["columns"])
            for row in t["rows"]:
                sh.append([_num(v) for v in row])
            for c in sh[1]:
                c.font = bold
    else:
        ws.title = "Text"
        ws.append(["Paragraph"])
        for p in [p for p in data.get("text", "").split("\n") if p.strip()]:
            ws.append([p])
        ws.column_dimensions["A"].width = 120
    if data.get("links"):
        sh = wb.create_sheet("Links")
        sh.append(["Text", "URL"])
        for l in data["links"]:
            sh.append([l["text"], l["url"]])
    info = wb.create_sheet("Source")
    info.append(["Title", data.get("title", "")])
    info.append(["URL", data.get("url", "")])
    info.append(["Saved by Aria", datetime.now().strftime("%Y-%m-%d %H:%M")])
    for sh in wb.worksheets:
        if sh.max_row >= 1 and sh.title not in ("Source",):
            for c in sh[1]:
                c.font = bold
            sh.freeze_panes = "A2"
    wb.save(path)


def _num(v):
    try:
        s = str(v).replace(",", "")
        return float(s) if re.fullmatch(r"-?\d+(\.\d+)?", s) else v
    except Exception:
        return v


def _to_docx(data: dict, path: Path, name: str) -> None:
    from docx import Document

    doc = Document()
    doc.add_heading(name, level=1)
    if data.get("url"):
        doc.add_paragraph(f"Source: {data['url']}")
    if data["kind"] == "transcript":
        doc.add_heading("Transcript", level=2)
        for t, text in _paragraphs(data["segments"]):
            p = doc.add_paragraph()
            p.add_run(f"[{_ts(t)}] ").bold = True
            p.add_run(text)
    else:
        for para in [p for p in data.get("text", "").split("\n") if p.strip()]:
            doc.add_paragraph(para)
        for i, t in enumerate(data.get("tables") or [], 1):
            doc.add_heading(f"Table {i}", level=2)
            tbl = doc.add_table(rows=1, cols=len(t["columns"]))
            tbl.style = "Light Grid Accent 1"
            for c, h in zip(tbl.rows[0].cells, t["columns"]):
                c.text = str(h)
            for row in t["rows"][:300]:
                cells = tbl.add_row().cells
                for c, v in zip(cells, row):
                    c.text = str(v)
    doc.add_paragraph(f"Saved by Aria on {datetime.now().strftime('%d %B %Y, %H:%M')}.")
    doc.save(path)


def _to_csv(data: dict, path: Path, name: str) -> None:
    import csv

    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if data["kind"] == "transcript":
            w.writerow(["start", "seconds", "text"])
            for t, text in data["segments"]:
                w.writerow([_ts(t), round(t, 1), text])
        elif data.get("tables"):
            t = data["tables"][0]
            w.writerow(t["columns"])
            w.writerows(t["rows"])
        else:
            w.writerow(["paragraph"])
            for p in [p for p in data.get("text", "").split("\n") if p.strip()]:
                w.writerow([p])


def _to_markdown(data: dict, name: str) -> str:
    lines = ["---", "tags: [air, export]", f"source: {json.dumps(data.get('url', ''))}",
             f"saved: {datetime.now().strftime('%Y-%m-%d %H:%M')}", "---", f"# {name}", ""]
    if data.get("url"):
        lines += [f"Source: <{data['url']}>", ""]
    if data["kind"] == "transcript":
        for t, text in _paragraphs(data["segments"]):
            lines += [f"**[{_ts(t)}]** {text}", ""]
    else:
        lines += [data.get("text", ""), ""]
        for i, t in enumerate(data.get("tables") or [], 1):
            cols = [str(c).replace("|", "\\|") for c in t["columns"]]
            lines += [f"## Table {i}", "", "| " + " | ".join(cols) + " |", "|" + " --- |" * len(cols)]
            for row in t["rows"][:300]:
                lines.append("| " + " | ".join(str(v).replace("|", "\\|") for v in row) + " |")
            lines.append("")
    return "\n".join(lines)
