"""Gemini client for Penpal replies."""

from __future__ import annotations

import logging
from typing import Any

from django.conf import settings
from google import genai
from google.genai import types

from .prompts import MATH_VISION_PROMPT, build_system_prompt

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


def _clean_reply(text: str, keep_newlines: bool = False) -> str:
    text = (text or "").strip()
    # Strip accidental markdown fences / labels.
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if len(lines) > 2 else lines).strip()
    for prefix in ("Penpal:", "Reply:", "Note:"):
        if text.lower().startswith(prefix.lower()):
            text = text[len(prefix) :].strip()
    if keep_newlines:
        # Math steps: keep line structure (one step per line), collapse
        # only intra-line whitespace and drop blank lines.
        lines = [" ".join(line.split()) for line in text.splitlines()]
        return "\n".join(line for line in lines if line)
    # Prose: collapse all whitespace for handwriting layout.
    return " ".join(text.split())


def transcribe_math(image_bytes: bytes, mime_type: str = "image/png") -> str:
    """
    Read handwritten maths from an image and return it as plain ASCII math.

    This exists because Vision's text recogniser is built for words and
    mangles handwritten notation (it turns "1/2 + 1/3" into "2 + 43").
    A vision model reads the layout properly — fractions, powers, roots.
    Returns "" when nothing legible is found.
    """
    if not image_bytes:
        raise GeminiError("No image supplied.")

    client = _client()
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=[
                types.Content(
                    role="user",
                    parts=[
                        types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
                        types.Part.from_text(
                            text="Transcribe the handwritten maths in this image."
                        ),
                    ],
                )
            ],
            config=types.GenerateContentConfig(
                system_instruction=MATH_VISION_PROMPT,
                # Transcription is not a creative task.
                temperature=0.0,
                max_output_tokens=180,
            ),
        )
    except Exception as exc:  # noqa: BLE001 — surface as API error
        logger.exception("Gemini math transcription failed")
        raise GeminiError(str(exc)) from exc

    text = (getattr(response, "text", None) or "").strip()
    # Strip any stray fences/labels; keep the expression on one line.
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if len(lines) > 2 else lines).strip()
    for prefix in ("Expression:", "Transcription:", "Answer:"):
        if text.lower().startswith(prefix.lower()):
            text = text[len(prefix):].strip()
    return " ".join(text.split())


def generate_reply(
    message: str,
    history: list[dict[str, Any]] | None = None,
    capability: str = "companion",
    mood: str = "warm",
    custom_mood: str = "",
    math_detail: str = "compact",
) -> str:
    """
    Turn the user's text into a short penpal note via Gemini.

    history items: {"role": "user"|"assistant", "content": "..."}
    capability: "companion" (moods: warm/playful/thoughtful/coach/custom)
                or "mathematician" (math_detail: answer/compact/full)
    """
    message = (message or "").strip()
    if not message:
        raise GeminiError("Message is empty.")

    is_math = (capability or "").strip().lower() == "mathematician"

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
                system_instruction=build_system_prompt(
                    capability=capability,
                    mood=mood,
                    custom_mood=custom_mood,
                    math_detail=math_detail,
                ),
                # Math needs precision, conversation needs life.
                temperature=0.2 if is_math else 0.9,
                top_p=0.95,
                # Full-detail solutions run longer than companion notes
                # (multi-part problems, verification, calculus working).
                max_output_tokens=1000 if is_math else 220,
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

    cleaned = _clean_reply(text, keep_newlines=is_math)
    if not cleaned:
        raise GeminiError("Gemini returned an empty reply.")
    return cleaned
