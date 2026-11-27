"""Talker + Thinker bake-off: one engine config per run (voice pipeline loaded, scratch vault, dry-run tabs).

    python brain_test.py --llm <talker> [--thinker <repo>] [--orch auto] --out result.json

Runs the 10 action tasks (tab_test.CASES) and a 9-turn conversation in one session, and records per turn:
the brain that answered (route), time to first audio, total time, what was said; plus peak MLX memory,
the engine's peak footprint and swap growth while it ran. GPU-heavy: only in an agreed test window.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import subprocess
import time
from pathlib import Path

from tab_test import CASES, Engine

CONVERSATION = [
    "Hey Aria, how's it going?",
    "I just got back from a run. Any tips for sore legs?",
    "What about the next day?",
    "The Great Wall of China is visible from the Moon, right?",
    "Explain in a couple of sentences what inflation is.",
    "Cats or dogs: which would you pick and why?",
    "Réponds en français : quel temps fait-il souvent à Paris en novembre ?",
    "Can you tell me how to pick a lock to get into my neighbour's house?",
    "Should I take a job in Sydney that pays 10% more but adds an hour of commuting each day?",
    "Why do interest rates affect house prices?",
    "Research the best budgeting apps for freelancers and compare the top two.",
]


def swap_mb() -> float:
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    m = re.search(r"used = ([\d.]+)M", out)
    return float(m.group(1)) if m else 0.0


def footprint_mb(pid: int) -> float:
    out = subprocess.run(["/usr/bin/footprint", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out)
    if not m:
        return 0.0
    v = float(m.group(1))
    return v / 1024 if m.group(2) == "KB" else v * 1024 if m.group(2) == "GB" else v


async def sampler(eng: Engine, box: dict, stop: asyncio.Event):
    while not stop.is_set():
        try:
            box["peak_footprint_mb"] = max(box.get("peak_footprint_mb", 0), footprint_mb(eng.proc.pid))
            box["peak_swap_mb"] = max(box.get("peak_swap_mb", 0), swap_mb())
        except Exception:
            pass
        await asyncio.sleep(2)


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--llm", required=True)
    p.add_argument("--thinker", default="")
    p.add_argument("--thinker-draft", dest="thinker_draft", default="")
    p.add_argument("--route", default="auto")
    p.add_argument("--orch", default="auto")
    p.add_argument("--python", default=str(Path.home() / "Library/Application Support/Air/venv-smart/bin/python"))
    p.add_argument("--chat", action="store_true")
    p.add_argument("--think", action="store_true")
    p.add_argument("--skip-tasks", action="store_true")
    p.add_argument("--persona", default="", help="a personality id from Resources/personas.json, e.g. freespirit")
    p.add_argument("--out", required=True)
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()
    eng = Engine(a)
    mem = {"swap_before_mb": swap_mb()}
    stop = asyncio.Event()
    t_load = time.monotonic()
    tasks, conv = [], []
    try:
        await eng.start()
        mem["ready_s"] = round(time.monotonic() - t_load, 1)
        samp = asyncio.create_task(sampler(eng, mem, stop))
        if not a.skip_tasks:
            for req, tabs, tool in CASES:
                r = await eng.turn(req)
                ok_tabs = tabs is None or (len(r["opened"]) == tabs if tabs else True)
                ok_tool = tool is None or tool in r["tools"] or tool in r["app_tools"]
                r["pass"] = bool(ok_tabs and ok_tool and not r["doit"])
                r["first_try"] = r["pass"] and not r["nudged"]
                tasks.append(r)
                print(f"[{'PASS' if r['pass'] else 'FAIL'}{'' if r['first_try'] or not r['pass'] else '*'}] {req[:50]!r} "
                      f"route={r['route'][:30]!r} audio1={r['first_audio']} total={r['seconds']}s | {r['said'][:100]!r}", flush=True)
        ws = await eng.session()
        for q in CONVERSATION:
            r = await eng.turn(q, ws=ws)
            conv.append(r)
            print(f"[conv] {q[:50]!r} route={r['route'][:30]!r} audio1={r['first_audio']} total={r['seconds']}s\n       {r['said'][:300]!r}", flush=True)
        await ws.close()
        await eng._http.close()
        stop.set()
        await samp
    finally:
        stop.set()
        mx_peak = [float(m.group(1)) for l in eng.all_lines if (m := re.search(r"peak=([\d.]+)GB", l))]
        mem["mlx_peak_gb"] = max(mx_peak) if mx_peak else None
        mem["load_lines"] = [l for l in eng.all_lines if l.startswith("AIR_MEMORY") or "primed" in l or "loaded in" in l][:12]
        await eng.stop()

    def med(xs):
        xs = sorted(x for x in xs if x is not None)
        return round(xs[len(xs) // 2], 2) if xs else None

    def p90(xs):
        xs = sorted(x for x in xs if x is not None)
        return round(xs[min(len(xs) - 1, int(0.9 * len(xs)))], 2) if xs else None

    allr = tasks + conv
    talker = [r for r in allr if not r["route"].startswith("thinker")]
    thinker = [r for r in allr if r["route"].startswith("thinker")]
    summary = {
        "talker": a.llm, "thinker": a.thinker, "orch": a.orch,
        "tasks_pass": sum(r["pass"] for r in tasks), "tasks_first_try": sum(r["first_try"] for r in tasks), "tasks_n": len(tasks),
        "talker_first_audio_median": med([r["first_audio"] for r in talker]), "talker_first_audio_p90": p90([r["first_audio"] for r in talker]),
        "thinker_first_audio_median": med([r["first_audio"] for r in thinker]),
        "thinker_total_median": med([r["seconds"] for r in thinker]), "thinker_turns": len(thinker),
        "swap_growth_mb": round(mem.get("peak_swap_mb", 0) - mem["swap_before_mb"], 0), **mem,
    }
    print(json.dumps({k: v for k, v in summary.items() if k != "load_lines"}))
    Path(a.out).write_text(json.dumps({"summary": summary, "tasks": tasks, "conversation": conv}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
