"""Gemini client for Penpal replies."""

from __future__ import annotations

import logging
from typing import Any

from django.conf import settings
from google import genai
from google.genai import types

from .prompts import PENPAL_SYSTEM_PROMPT

logger = logging.getLogger(__name__)


class GeminiError(Exception):
    """Raised when Gemini cannot produce a reply."""


def _client() -> genai.Client:
    key = (settings.GEMINI_API_KEY or "").strip()
    if not key or key.startswith("your_"):
        raise GeminiError(
            "GEMINI_API_KEY is missing. Copy .env.example to .env and add your key."
        )
    return genai.Client(api_key=key)


def _clean_reply(text: str) -> str:
    text = (text or "").strip()
    # Strip accidental markdown fences / labels.
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if len(lines) > 2 else lines).strip()
    for prefix in ("Penpal:", "Reply:", "Note:"):
        if text.lower().startswith(prefix.lower()):
            text = text[len(prefix) :].strip()
    # Collapse whitespace for handwriting layout.
    return " ".join(text.split())


def generate_reply(
    message: str,
    history: list[dict[str, Any]] | None = None,
) -> str:
    """
    Turn the user's text into a short penpal note via Gemini.

    history items: {"role": "user"|"assistant", "content": "..."}
    """
    message = (message or "").strip()
    if not message:
        raise GeminiError("Message is empty.")

    contents: list[types.Content] = []
    for turn in history or []:
        role = (turn.get("role") or "").strip().lower()
        content = (turn.get("content") or "").strip()
        if not content:
            continue
        # Gemini uses "user" / "model"
        gemini_role = "user" if role in ("user", "human") else "model"
        contents.append(
            types.Content(
                role=gemini_role,
                parts=[types.Part.from_text(text=content)],
            )
        )

    contents.append(
        types.Content(
            role="user",
            parts=[types.Part.from_text(text=message)],
        )
    )

    client = _client()
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=PENPAL_SYSTEM_PROMPT,
                temperature=0.9,
                top_p=0.95,
                max_output_tokens=220,
            ),
        )
    except Exception as exc:  # noqa: BLE001 — surface as API error
        logger.exception("Gemini generate_content failed")
        raise GeminiError(str(exc)) from exc

    text = getattr(response, "text", None) or ""
    if not text and getattr(response, "candidates", None):
        # Fallback: assemble from parts if .text is empty.
        parts: list[str] = []
        for cand in response.candidates:
            content = getattr(cand, "content", None)
            if not content:
                continue
            for part in getattr(content, "parts", None) or []:
                t = getattr(part, "text", None)
                if t:
                    parts.append(t)
        text = "\n".join(parts)

    cleaned = _clean_reply(text)
    if not cleaned:
        raise GeminiError("Gemini returned an empty reply.")
    return cleaned
