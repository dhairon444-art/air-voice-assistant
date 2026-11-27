"""Cloud heavy brain (Claude or Gemini), used only after the user says yes for that request.

The key comes from the app (Keychain) through the environment and is never logged. Only the
question and the plain conversation are sent: no tool schema, no profile or recalled notes unless
the owner allowed them in Settings, never screenshots.
"""

from __future__ import annotations

import re
from typing import Iterator

# Published per-million-token prices (USD) used for the spoken/logged estimate; unknown models: no estimate.
PRICES = {
    "claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0), "claude-haiku-5-5": (0.10, 0.50),
    "claude-fable-5-2": (8.0, 40.0), "claude-opus-5": (5.0, 25.0), "claude-sonnet-5": (2.0, 10.0),
}
# Models for which the server-side refusal fallback ("default" routing) is requested.
FALLBACK_OK = {"claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5"}


def parse_ref(ref: str) -> tuple[str, str] | None:
    """'cloud:anthropic:claude-opus-5-5' -> ('anthropic', 'claude-opus-5-5')."""
    m = re.match(r"^cloud:(anthropic|google):(.+)$", ref or "")
    if not m:
        return None
    model = m.group(2)
    if model == "default":
        model = "claude-opus-5-5" if m.group(1) == "anthropic" else "gemini-2.5-flash"
    return m.group(1), model


def display_name(provider: str) -> str:
    return "Claude" if provider == "anthropic" else "Gemini"


def plain_history(messages: list, allow_context: bool) -> list[dict]:
    """The conversation as user/assistant text. Tool results become short notes; recalled memory and
    screen text (appended to user turns after a blank line and '(') are dropped unless allowed."""
    out: list[dict] = []
    for m in messages:
        role, content = m.get("role"), m.get("content") or ""
        if role == "system" or not isinstance(content, str):
            continue
        if role == "tool":
            role, content = "user", f"(A tool result: {content[:1500]})"
        elif role == "user" and not allow_context:
            content = content.split("\n\n(")[0]
        if role not in ("user", "assistant") or not content.strip():
            continue
        if out and out[-1]["role"] == role:
            out[-1]["content"] += "\n\n" + content
        else:
            out.append({"role": role, "content": content})
    while out and out[0]["role"] != "user":
        out.pop(0)
    return out


class CloudBrain:
    def __init__(self, provider: str, model: str, key: str):
        self.provider, self.model, self.key = provider, model, key
        self.usage = (0, 0)

    def stream(self, system: str, history: list[dict], max_tokens: int = 8000) -> Iterator[str]:
        """Text pieces of the answer. Raises on network/API errors (the caller falls back to local)."""
        if self.provider == "anthropic":
            yield from self._anthropic(system, history, max_tokens)
        else:
            yield from self._gemini(system, history, max_tokens)

    def _anthropic(self, system: str, history: list[dict], max_tokens: int) -> Iterator[str]:
        import anthropic

        client = anthropic.Anthropic(api_key=self.key, max_retries=1, timeout=120.0)
        kwargs = dict(model=self.model, max_tokens=max_tokens, system=system, messages=history)
        if self.model in FALLBACK_OK:
            # If the model declines, the API re-runs the request on a fallback model in the same call.
            ctx = client.beta.messages.stream(betas=["server-side-fallback-2026-07-01"], fallbacks="default", **kwargs)
        else:
            ctx = client.messages.stream(**kwargs)
        with ctx as stream:
            for text in stream.text_stream:
                yield text
            final = stream.get_final_message()
        self.usage = (final.usage.input_tokens or 0, final.usage.output_tokens or 0)
        if final.stop_reason == "refusal":
            yield "\n\nI can't help with that one."

    def _gemini(self, system: str, history: list[dict], max_tokens: int) -> Iterator[str]:
        from google import genai
        from google.genai import types

        client = genai.Client(api_key=self.key)
        contents = [types.Content(role="model" if m["role"] == "assistant" else "user",
                                  parts=[types.Part(text=m["content"])]) for m in history]
        last = None
        for chunk in client.models.generate_content_stream(
                model=self.model, contents=contents,
                config=types.GenerateContentConfig(system_instruction=system, max_output_tokens=max_tokens)):
            last = chunk
            if chunk.text:
                yield chunk.text
        um = getattr(last, "usage_metadata", None)
        if um is not None:
            self.usage = (um.prompt_token_count or 0, um.candidates_token_count or 0)

    def cost_note(self) -> str:
        i, o = self.usage
        p = PRICES.get(self.model)
        cost = f", about US${i * p[0] / 1e6 + o * p[1] / 1e6:.3f}" if p else ""
        return f"{display_name(self.provider)} {self.model}: {i} tokens in, {o} out{cost}"
