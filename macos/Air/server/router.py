"""Orchestrator routing: which specialist (if any) should shape Aria's answer.

A small sentence-embedding model (bge-small-en-v1.5, int8 ONNX, 34 MB, MIT) on the CPU compares the
request with each installed specialist's role and expertise in ~2 ms. Clear matches route straight away;
close or weak ones stay with Aria (or go to the loaded brain for a constrained pick, see aria_server).
Nothing here touches the GPU.
"""
from __future__ import annotations

import re
from pathlib import Path

import numpy as np

# Requests Aria handles herself whatever the score: tools, chat, quick facts.
_ARIA_ONLY = re.compile(
    r"^\W*(hi|hey|hello|thanks|thank you|ok(ay)?|bye|good (morning|night))\b|"
    r"\b(open|quit|close|switch to|launch) (the )?\w+( app)?\b|\b(remind me|add (an? )?(event|reminder)|calendar|"
    r"volume|mute|play|pause|skip|what time|what's the time|timer|alarm|email|message|text (him|her)|"
    r"my (files?|screen|browser|tabs?|documents?)|watch my screen|look at (my|this)|weather)\b", re.I)


class Router:
    def __init__(self, model_dir: str):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        d = Path(model_dir)
        self.tok = Tokenizer.from_file(str(d / "tokenizer.json"))
        self.tok.enable_truncation(256)
        so = ort.SessionOptions()
        so.intra_op_num_threads = 2
        self.sess = ort.InferenceSession(str(d / "model_quantized.onnx"), so, providers=["CPUExecutionProvider"])
        self.inputs = [i.name for i in self.sess.get_inputs()]
        self.ids: list[str] = []
        self.names: list[str] = []
        self.mat = np.zeros((0, 384), np.float32)

    def embed(self, texts: list[str], query: bool = False) -> np.ndarray:
        if query:   # bge: an instruction prefix for short queries
            texts = ["Represent this sentence for searching relevant passages: " + t for t in texts]
        enc = self.tok.encode_batch(texts)
        n = max(len(e.ids) for e in enc)
        ids = np.array([e.ids + [0] * (n - len(e.ids)) for e in enc], np.int64)
        mask = np.array([e.attention_mask + [0] * (n - len(e.ids)) for e in enc], np.int64)
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self.inputs:
            feed["token_type_ids"] = np.zeros_like(ids)
        out = self.sess.run(None, feed)[0][:, 0]
        return out / np.linalg.norm(out, axis=1, keepdims=True)

    ARIA_ANCHORS = [
        "Hi, how are you today?", "Tell me a joke.", "What's the capital of France?", "How tall is Mount Everest?",
        "What's the meaning of this word?", "Tell me a fun fact.", "What should we talk about?", "Summarise this for me.",
        "Translate hello into Spanish.", "What year did the Berlin Wall fall?", "Who wrote Pride and Prejudice?",
        "Can you help me with something?", "What's your name?", "Spell necessary.", "Convert 5 miles to kilometres.",
    ]

    def set_specialists(self, items: list[dict]) -> None:
        """items: professionals.json entries (installed ones). Built once per session. Each specialist gets
        several documents (profile + its example questions); its score is the best match among them."""
        docs, owner, kind = [], [], []
        self.ids, self.names = [], []
        for k, p in enumerate(items):
            focus = ", ".join(p.get("focus") or [])
            frameworks = ", ".join(p.get("frameworks") or [])
            docs.append(f"{p['name']}: {p.get('role', '')}. Expertise: {p.get('expertise', '')}. "
                        f"Focus: {focus}. Methods: {frameworks}.")
            owner.append(k); kind.append(0)
            docs.append(f"Questions for a {p['name']} about {p.get('expertise', '')}")
            owner.append(k); kind.append(0)
            for ex in p.get("examples") or []:
                u = ex[0] if isinstance(ex, (list, tuple)) else str(ex)
                docs.append(u)
                owner.append(k); kind.append(1)
            self.ids.append(p["id"])
            self.names.append(p["name"])
        self.owner = np.array(owner)
        self.kind = np.array(kind)
        self.mat = self.embed(docs) if docs else np.zeros((0, 384), np.float32)
        self.anchor = self.embed(self.ARIA_ANCHORS)

    def route(self, text: str, lo: float = 0.45, margin: float = 0.04) -> dict:
        """{'mode': 'aria'|'lens'|'unsure', 'id', 'name', 'score', 'second', 'top': [(name, score)...]}"""
        if not self.ids or not text.strip():
            return {"mode": "aria", "reason": "no specialists"}
        if _ARIA_ONLY.search(text):
            return {"mode": "aria", "reason": "Aria handles this herself (tools or chat)"}
        q = self.embed([text], query=True)[0]
        doc = self.mat @ q
        # Profile and expertise docs count most; example questions help but can match off-topic.
        prof = np.full(len(self.ids), -1.0)
        exam = np.full(len(self.ids), -1.0)
        np.maximum.at(prof, self.owner[self.kind == 0], doc[self.kind == 0])
        np.maximum.at(exam, self.owner[self.kind == 1], doc[self.kind == 1])
        sims = np.where(exam > -1, 0.65 * prof + 0.35 * exam, prof)
        aria = float((self.anchor @ q).max())
        order = np.argsort(-sims)
        best, second = int(order[0]), int(order[1]) if len(order) > 1 else int(order[0])
        top = [(self.names[i], round(float(sims[i]), 3)) for i in order[:3]]
        self.last_order = [self.ids[i] for i in order[:5]]
        res = {"id": self.ids[best], "name": self.names[best], "score": float(sims[best]),
               "second": float(sims[second]), "aria": round(aria, 3), "top": top}
        if sims[best] < lo or sims[best] < aria + 0.02:
            res.update(mode="aria", reason="no specialist fits better than Aria herself")
        elif sims[best] - sims[second] < margin:
            res.update(mode="unsure", reason=f"close between {self.names[best]} and {self.names[second]}",
                       candidates=[self.ids[i] for i in order[:3]])
        else:
            res.update(mode="lens", reason="clear match")
        return res
