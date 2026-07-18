"""Gemini client for Penpal replies."""

from __future__ import annotations

import logging
from typing import Any

from django.conf import settings
from google import genai
from google.genai import types

from . import mathengine
from .prompts import (
    MATH_CORRECTOR_NOTE,
    MATH_VERIFIER_PROMPT,
    MATH_VISION_PROMPT,
    build_system_prompt,
)

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


def _extract_text(response: Any) -> str:
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
    return text


def _build_contents(
    history: list[dict[str, Any]] | None, message: str
) -> list[types.Content]:
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
        types.Content(role="user", parts=[types.Part.from_text(text=message)])
    )
    return contents


def _verify_math(
    client: genai.Client, problem_parts: list[types.Part], solution: str
) -> dict:
    """
    Independent referee pass. `problem_parts` is the problem statement —
    text, or an image plus text for boxed problems.
    Returns {"verdict": ..., "reason": ...}.
    """
    import json
    import re

    parts = [types.Part.from_text(text="PROBLEM:")]
    parts.extend(problem_parts)
    parts.append(types.Part.from_text(text=f"\nSOLUTION:\n{solution}"))
    contents = [types.Content(role="user", parts=parts)]

    # JSON mode + zero thinking budget: the referee must spend its tokens on
    # the verdict, not on visible reasoning that truncates the JSON.
    base = dict(
        system_instruction=MATH_VERIFIER_PROMPT,
        temperature=0.0,
        max_output_tokens=1500,
        response_mime_type="application/json",
    )
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents,
            config=types.GenerateContentConfig(
                **base,
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
    except Exception as exc:  # noqa: BLE001 — model may not accept the knobs
        if not any(k in str(exc).lower() for k in ("thinking", "response_mime")):
            raise
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=MATH_VERIFIER_PROMPT,
                temperature=0.0,
                max_output_tokens=1500,
            ),
        )

    text = _extract_text(response).strip()
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if len(lines) > 2 else lines).strip()
    try:
        verdict = json.loads(text)
    except json.JSONDecodeError:
        # Salvage: first {...} block, then a raw-text sniff. Truncated output
        # must never take down the reply — worst case we call it correct.
        m = re.search(r"\{.*\}", text, re.S)
        verdict = None
        if m:
            try:
                verdict = json.loads(m.group(0))
            except json.JSONDecodeError:
                verdict = None
        if verdict is None:
            wrong = '"verdict"' in text and '"wrong"' in text
            reason_m = re.search(r'"reason"\s*:\s*"([^"]*)', text)
            verdict = {
                "verdict": "wrong" if wrong else "correct",
                "reason": reason_m.group(1) if reason_m else "",
            }
    if not isinstance(verdict, dict) or "verdict" not in verdict:
        raise ValueError("malformed verifier output")
    return verdict


def _run_math_pipeline(
    client: genai.Client,
    contents: list[types.Content],
    system_prompt: str,
    verify_parts: list[types.Part],
) -> str:
    """
    Shared solve → verify → correct loop for text and image problems.
    Verification fails open: the draft is returned if checking breaks.
    """
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,  # math is not a creative task
                top_p=0.95,
                # Long enough for a full page of multi-part working — on
                # thinking models this budget also feeds the reasoning.
                max_output_tokens=8000,
            ),
        )
    except Exception as exc:  # noqa: BLE001 — surface as API error
        logger.exception("Gemini math solve failed")
        raise GeminiError(str(exc)) from exc

    draft = _clean_reply(_extract_text(response), keep_newlines=True)
    if not draft:
        raise GeminiError("Gemini returned an empty reply.")

    # Referee pass + one bounded correction. Never let checking break a reply.
    try:
        verdict = _verify_math(client, verify_parts, draft)
        if str(verdict.get("verdict")).lower() != "wrong":
            return draft
        reason = str(verdict.get("reason") or "final answer incorrect")[:300]
        logger.info("Math verifier flagged solution: %s", reason)
        retry_contents = contents + [
            types.Content(
                role="model", parts=[types.Part.from_text(text=draft)]
            ),
            types.Content(
                role="user",
                parts=[
                    types.Part.from_text(
                        text=MATH_CORRECTOR_NOTE.format(reason=reason)
                    )
                ],
            ),
        ]
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=retry_contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,
                top_p=0.95,
                max_output_tokens=2000,
            ),
        )
        corrected = _clean_reply(_extract_text(response), keep_newlines=True)
        return corrected or draft
    except Exception:  # noqa: BLE001 — fail open to the draft
        logger.exception("Math verification pass failed; returning draft")
        return draft


def _math_reply(
    client: genai.Client,
    history: list[dict[str, Any]] | None,
    message: str,
    system_prompt: str,
) -> str:
    """
    God-level math pipeline (text input):
      1. SymPy computes exact results where it can → injected as [CAS]
         ground truth for the solver.
      2–4. Shared solve → verify → correct loop.
    """
    cas = mathengine.cas_hint(message)
    solver_message = f"{message}\n\n[CAS]\n{cas}" if cas else message
    contents = _build_contents(history, solver_message)
    return _run_math_pipeline(
        client, contents, system_prompt,
        verify_parts=[types.Part.from_text(text=solver_message)],
    )


def solve_math_image(
    image_bytes: bytes,
    mime_type: str = "image/png",
    history: list[dict[str, Any]] | None = None,
    math_detail: str = "compact",
) -> str:
    """
    Solve a boxed handwritten problem straight from its image — no OCR,
    no transcription step. The model reads the notation exactly as drawn,
    and the same referee verification loop guards the answer.
    """
    if not image_bytes:
        raise GeminiError("No image supplied.")

    system_prompt = build_system_prompt(
        capability="mathematician", math_detail=math_detail
    )
    image_part = types.Part.from_bytes(data=image_bytes, mime_type=mime_type)
    prompt_part = types.Part.from_text(
        text="Solve the handwritten problem in this image."
    )

    contents = _build_contents(history, "")[:-1]  # history only
    contents.append(
        types.Content(role="user", parts=[image_part, prompt_part])
    )

    client = _client()
    return _run_math_pipeline(
        client, contents, system_prompt,
        verify_parts=[image_part, prompt_part],
    )


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
                or "mathematician" (math_detail: answer/compact/full/proof)
    """
    message = (message or "").strip()
    if not message:
        raise GeminiError("Message is empty.")

    is_math = (capability or "").strip().lower() == "mathematician"
    system_prompt = build_system_prompt(
        capability=capability,
        mood=mood,
        custom_mood=custom_mood,
        math_detail=math_detail,
    )
    client = _client()

    if is_math:
        return _math_reply(client, history, message, system_prompt)

    contents = _build_contents(history, message)
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                # Conversation needs life.
                temperature=0.9,
                top_p=0.95,
                max_output_tokens=220,
            ),
        )
    except Exception as exc:  # noqa: BLE001 — surface as API error
        logger.exception("Gemini generate_content failed")
        raise GeminiError(str(exc)) from exc

    cleaned = _clean_reply(_extract_text(response), keep_newlines=False)
    if not cleaned:
        raise GeminiError("Gemini returned an empty reply.")
    return cleaned
