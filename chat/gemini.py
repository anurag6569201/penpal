"""Gemini client for Penpal replies."""

from __future__ import annotations

import html as html_lib
import ipaddress
import json
import logging
import math
import re
import unicodedata
from urllib.parse import urlparse
from typing import Any

from django.conf import settings
from google import genai
from google.genai import types

from . import mathengine, routing, telemetry, tracer
from .prompts import (
    ARRANGER_SYSTEM_PROMPT,
    GRADER_SYSTEM_PROMPT,
    DEBATE_SYSTEM_PROMPT,
    IMPORT_SYSTEM_PROMPT,
    ILLUSTRATOR_SYSTEM_PROMPT,
    INTERACTIVE_REPAIR_PROMPT,
    INTERACTIVE_REVIEW_PROMPT,
    INTERACTIVE_SYSTEM_PROMPT,
    LANGUAGE_PRACTICE_SYSTEM_PROMPT,
    MATH_CORRECTOR_NOTE,
    MATH_DETAIL,
    PRACTICE_SYSTEM_PROMPT,
    MATH_VERIFIER_PROMPT,
    MATH_VISION_PROMPT,
    WORKSHEET_CORRECTOR_NOTE,
    WORKSHEET_SYSTEM_PROMPT,
    WORKSHEET_VERIFIER_PROMPT,
    VISION_CLASSIFIER_PROMPT,
    VISION_COMPANION_NOTE,
    build_system_prompt,
    illustrator_trace_gate_prompt,
    language_partner_prompt,
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
    # A request with no deadline can pin a worker until the process is
    # restarted. Large interactive builds legitimately run for minutes, so the
    # ceiling is generous — it exists to end hangs, not to cut work short.
    timeout_seconds = getattr(settings, "GEMINI_TIMEOUT_SECONDS", 240)
    try:
        return genai.Client(
            api_key=key,
            http_options=types.HttpOptions(timeout=int(timeout_seconds) * 1000),
        )
    except Exception:  # noqa: BLE001 — older SDKs lack the option
        return genai.Client(api_key=key)


# The model occasionally leaks its own stage directions onto the page —
# "(45 words, plain):", "(under 45 words)", "(keep it short):" — despite the
# prompt. These are meta about the reply, never part of it.
_META_PAREN = re.compile(
    r"\(\s*[^)]{0,12}?\d+\s*words?[^)]*\)\s*:?\s*"
    r"|\(\s*(?:plain(?:\s+text)?|no\s+markdown|keep\s+it\s+\w+|tone:[^)]*)\s*\)\s*:?\s*",
    re.IGNORECASE,
)

# Handwriting renders only trained glyphs; smart punctuation silently
# disappears from the page. Fold it to drawable ASCII equivalents.
_SMART_PUNCT = {
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "-", "…": "...", " ": " ",
}


def _fold_for_ink(text: str) -> str:
    """Fold accented Latin letters to their base letter (cliché → cliche).

    The renderer drops characters it has no glyph for, so without folding
    "cliché" draws as "clich" — a typo in the user's own hand. Non-Latin
    characters without an ASCII base (π, √, …) pass through untouched.
    """
    out = []
    for ch in text:
        if ord(ch) < 128:
            out.append(ch)
            continue
        folded = unicodedata.normalize("NFKD", ch)
        stripped = "".join(c for c in folded if not unicodedata.combining(c))
        if stripped and all(ord(c) < 128 for c in stripped):
            out.append(stripped)
        else:
            out.append(ch)
    return "".join(out)


def _clean_reply(text: str, keep_newlines: bool = False) -> str:
    text = (text or "").strip()
    # Strip accidental markdown fences / labels.
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if len(lines) > 2 else lines).strip()
    for prefix in ("Penpal:", "Reply:", "Note:"):
        if text.lower().startswith(prefix.lower()):
            text = text[len(prefix) :].strip()
    text = _META_PAREN.sub("", text)
    for src, dst in _SMART_PUNCT.items():
        text = text.replace(src, dst)
    if keep_newlines:
        # Math steps: keep line structure (one step per line), collapse
        # only intra-line whitespace and drop blank lines. No diacritic
        # folding here — NFKD would flatten x² to x2 and change the math.
        lines = [" ".join(line.split()) for line in text.splitlines()]
        return "\n".join(line for line in lines if line)
    # Prose is drawn with the user's trained glyphs: fold what the pen can't
    # draw, and drop markdown emphasis remnants the prompt already forbids.
    original = text
    text = text.replace("*", "").replace("`", "")
    text = _fold_for_ink(text)
    # Prose: collapse all whitespace for handwriting layout.
    result = " ".join(text.split())
    # SAFETY: sanitizing must never turn a real reply into "empty reply" —
    # if everything was stripped, fall back to the unsanitized text.
    if not result and original.strip():
        return " ".join(original.split())
    return result


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
                # Headroom for thinking-model reasoning tokens (see the
                # companion call) — 180 returned empty transcriptions on
                # gemini-2.5+/3.x models.
                max_output_tokens=1024,
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


def _agrees_with_cas(draft: str, cas_value: str) -> bool:
    """
    Does the written answer actually contain the value SymPy proved?

    Compared as whole tokens, so "42" does not count as containing "4".
    Conservative by design: anything unclear returns False and the LLM
    referee runs, because a false "they agree" would ship an unverified
    answer while reporting it as verified — the BB-03 failure mode.
    """
    import re

    if not cas_value:
        return False
    # Prefer the final answer line when there is one.
    lines = [ln for ln in draft.splitlines() if ln.strip()]
    tail = next((ln for ln in reversed(lines)
                 if ln.lower().lstrip().startswith("ans")), lines[-1] if lines else "")
    if not tail:
        return False

    def tokens(text: str) -> set[str]:
        return set(re.findall(r"-?\d+(?:\.\d+)?|[A-Za-z]+|[^\s\w]", text))

    wanted = tokens(cas_value)
    if not wanted:
        return False
    return wanted.issubset(tokens(tail))


def _account(model: str, response: Any) -> None:
    """PEN-27 — record what a call cost. Never raises."""
    prompt_tokens, output_tokens = routing.usage_from(response)
    if prompt_tokens or output_tokens:
        telemetry.record_usage(
            model, prompt_tokens, output_tokens,
            routing.estimate_cost(model, prompt_tokens, output_tokens))


def _extract_text(response: Any) -> str:
    # `.text` is a property that raises on some SDK builds when the candidate
    # holds no text part (tool call, safety block, thinking-only truncation).
    # An accessor must never be the thing that takes down a reply.
    try:
        text = getattr(response, "text", None) or ""
    except Exception:  # noqa: BLE001
        text = ""
    if not text and getattr(response, "candidates", None):
        # Fallback: assemble from parts if .text is empty.
        parts: list[str] = []
        try:
            candidates = list(response.candidates or [])
        except Exception:  # noqa: BLE001
            candidates = []
        for cand in candidates:
            content = getattr(cand, "content", None)
            if not content:
                continue
            for part in getattr(content, "parts", None) or []:
                # Thinking parts carry no answer; including them would feed
                # the model's scratchpad into the JSON parser.
                if getattr(part, "thought", False):
                    continue
                t = getattr(part, "text", None)
                if t:
                    parts.append(t)
        text = "\n".join(parts)
    return text


# A response that stopped here was cut off mid-answer rather than finished.
_TRUNCATING_FINISH_REASONS = {"MAX_TOKENS", "LENGTH", "TOKEN_LIMIT"}


def _finish_reason(response: Any) -> str:
    """Upper-case finish reason of the first candidate, or "" if unknown."""
    try:
        candidates = list(getattr(response, "candidates", None) or [])
    except Exception:  # noqa: BLE001
        return ""
    if not candidates:
        return ""
    raw = getattr(candidates[0], "finish_reason", None)
    if raw is None:
        return ""
    return str(getattr(raw, "name", raw)).strip().upper().rsplit(".", 1)[-1]


def _was_truncated(response: Any) -> bool:
    return _finish_reason(response) in _TRUNCATING_FINISH_REASONS


def _empty_response_reason(response: Any) -> str:
    """Explain an empty response using whatever the SDK reported."""
    finish = _finish_reason(response)
    if finish in _TRUNCATING_FINISH_REASONS:
        return (
            "Gemini hit its output limit before writing any answer "
            "(finish_reason=MAX_TOKENS)."
        )
    if finish in {"SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"}:
        return f"Gemini blocked the response (finish_reason={finish})."
    if finish == "RECITATION":
        return "Gemini stopped the response for recitation."
    feedback = getattr(response, "prompt_feedback", None)
    blocked = getattr(feedback, "block_reason", None) if feedback else None
    if blocked:
        return f"Gemini blocked the prompt ({blocked})."
    return f"Gemini returned an empty response (finish_reason={finish or 'unknown'})."


# Errors worth trying again unchanged: the service, not the request, failed.
_TRANSIENT_MARKERS = (
    "429", "500", "502", "503", "504",
    "unavailable", "overloaded", "resource_exhausted", "rate limit",
    "deadline", "timeout", "timed out", "internal error",
    "connection reset", "connection aborted", "temporarily",
)

# Errors caused by a config knob this model does not accept.
_CONFIG_MARKERS = (
    "thinking", "response_mime", "response_schema", "max_output_tokens",
    "not supported", "unsupported", "invalid_argument", "unknown field",
)


def _is_transient(exc: Exception) -> bool:
    text = str(exc).lower()
    return any(marker in text for marker in _TRANSIENT_MARKERS)


def _generate(
    client: genai.Client,
    model: str,
    contents: list[types.Content],
    *,
    attempts: int = 3,
    **config_kwargs: Any,
) -> Any:
    """
    `generate_content` that survives a bad minute.

    Two independent failure modes are handled here so no caller has to:
      * transient service errors (429/5xx/timeout) — retried with backoff;
      * config knobs the configured model rejects (thinking budget, JSON
        mode) — dropped one at a time and retried, because a plain-text
        answer we can still parse beats a hard failure.
    """
    import time

    knobs = dict(config_kwargs)
    transient_left = max(1, attempts) - 1
    downgrades_left = 4      # bounded by the number of droppable knobs
    backoff = 0.6

    while True:
        try:
            return client.models.generate_content(
                model=model,
                contents=contents,
                config=types.GenerateContentConfig(**knobs),
            )
        except Exception as exc:  # noqa: BLE001 — classified below
            lowered = str(exc).lower()
            # A rejected knob is checked first: retrying it unchanged can
            # only fail again, however much the message looks transient.
            if downgrades_left and any(m in lowered for m in _CONFIG_MARKERS):
                dropped = ""
                # Prefer the knob the error actually names; otherwise drop
                # the least valuable one still set.
                order = ("thinking_config", "response_schema",
                         "response_mime_type", "top_p")
                named = [k for k in order
                         if k in knobs and k.split("_")[0] in lowered]
                for knob in named + [k for k in order if k in knobs]:
                    knobs.pop(knob)
                    dropped = knob
                    break
                if not dropped and knobs.get("max_output_tokens", 0) > 8_000:
                    knobs["max_output_tokens"] = 8_000
                    dropped = "max_output_tokens"
                if dropped:
                    downgrades_left -= 1
                    logger.warning(
                        "Retrying %s without %s, which it rejected: %s",
                        model, dropped, exc,
                    )
                    continue
            if transient_left and _is_transient(exc):
                transient_left -= 1
                logger.warning("Retrying %s after a transient error: %s", model, exc)
                time.sleep(min(4.0, backoff))
                backoff *= 2
                continue
            raise


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
        telemetry.record(telemetry.VERIFY_SALVAGED, text[:120])
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
    route: routing.Route | None = None,
) -> str:
    """
    Shared solve → verify → correct loop for text and image problems.
    Verification fails open: the draft is returned if checking breaks.
    """
    route = route or routing.Route(settings.GEMINI_MODEL, "default")
    try:
        response = client.models.generate_content(
            model=route.model,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,  # math is not a creative task
                top_p=0.95,
                # Long enough for a full page of multi-part working — on
                # thinking models this budget also feeds the reasoning.
                max_output_tokens=route.max_output_tokens,
            ),
        )
    except Exception as exc:  # noqa: BLE001 — surface as API error
        logger.exception("Gemini math solve failed")
        raise GeminiError(str(exc)) from exc

    _account(route.model, response)
    draft = _clean_reply(_extract_text(response), keep_newlines=True)
    if not draft:
        raise GeminiError("Gemini returned an empty reply.")

    # PEN-29: when SymPy computed the answer exactly AND the model's final
    # answer agrees with it, there is nothing left for a referee to catch —
    # we already hold ground truth and the model reproduced it. Skipping the
    # second call there is most of the cost saving.
    #
    # Crucially this is NOT blind trust in the route: a model can ignore the
    # [CAS] block, and "the model invented an answer" is exactly what the
    # referee exists to catch. So the shortcut is gated on a free,
    # deterministic agreement check. Disagreement means the LLM referee runs,
    # which is precisely when it earns its cost.
    if route.skip_verification and _agrees_with_cas(draft, route.cas_value):
        telemetry.record(telemetry.VERIFY_CORRECT)
        telemetry.record(telemetry.SOLVE_COMPLETED)
        return draft

    # Referee pass + one bounded correction. Never let checking break a reply.
    try:
        verdict = _verify_math(client, verify_parts, draft)
        if str(verdict.get("verdict")).lower() != "wrong":
            telemetry.record(telemetry.VERIFY_CORRECT)
            telemetry.record(telemetry.SOLVE_COMPLETED)
            return draft
        telemetry.record(telemetry.VERIFY_WRONG)
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
        if corrected:
            telemetry.record(telemetry.VERIFY_CORRECTED)
        telemetry.record(telemetry.SOLVE_COMPLETED)
        return corrected or draft
    except Exception as exc:  # noqa: BLE001 — fail open to the draft
        # BB-03 lived here: this path ran on every request while looking fine.
        # It is now counted, and /api/health/ reports the coverage drop.
        telemetry.record(telemetry.VERIFY_FAILED_OPEN, str(exc))
        telemetry.record(telemetry.SOLVE_COMPLETED)
        logger.exception("Math verification pass failed; returning draft")
        return draft


def _math_reply(
    client: genai.Client,
    history: list[dict[str, Any]] | None,
    message: str,
    system_prompt: str,
    math_detail: str = "compact",
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
    route = routing.choose(message, cas_hint=cas, math_detail=math_detail)
    logger.debug("Math route: %s (%s)", route.model, route.reason)
    return _run_math_pipeline(
        client, contents, system_prompt,
        verify_parts=[types.Part.from_text(text=solver_message)],
        route=route,
    )


def solve_math_image(
    image_bytes: bytes,
    mime_type: str = "image/png",
    history: list[dict[str, Any]] | None = None,
    math_detail: str = "compact",
    question: str = "",
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
    prompt_part = types.Part.from_text(text=(
        question.strip()[:4000]
        or "Solve the handwritten problem in this image."
    ))

    contents = _build_contents(history, "")[:-1]  # history only
    contents.append(
        types.Content(role="user", parts=[image_part, prompt_part])
    )

    client = _client()
    return _run_math_pipeline(
        client, contents, system_prompt,
        verify_parts=[image_part, prompt_part],
    )


_FENCED_BLOCK = re.compile(r"```[A-Za-z0-9_+-]*[ \t]*\r?\n(.*?)(?:```|\Z)", re.S)

# A control character inside a JSON string is illegal; models emit real
# newlines inside HTML strings often enough to be worth repairing.
_BARE_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _strip_json_fences(text: str) -> str:
    """Return the most JSON-looking body from a possibly fenced response."""
    text = (text or "").strip()
    if "```" not in text:
        return text
    for match in _FENCED_BLOCK.finditer(text):
        body = match.group(1).strip()
        if body.startswith(("{", "[")):
            return body
    # A fence opened with no newline ("```json{...") or never closed.
    body = re.sub(r"^```[A-Za-z0-9_+-]*[ \t]*", "", text)
    return body.rsplit("```", 1)[0].strip() if body.endswith("```") else body.strip()


def _scan_json(text: str) -> tuple[str, str] | None:
    """
    Find the first JSON value in `text`, string-aware.

    Returns (body, closers). `closers` is "" when the value is complete, or
    the characters that would close a value the model was cut off mid-way
    through. Returns None when there is no plausible JSON at all.
    """
    start = -1
    for index, char in enumerate(text):
        if char in "{[":
            start = index
            break
    if start < 0:
        return None

    stack: list[str] = []
    in_string = False
    escaped = False
    end = len(text)
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "{[":
            stack.append("}" if char == "{" else "]")
        elif char in "}]":
            if not stack or stack.pop() != char:
                # Structurally broken rather than merely unfinished.
                end = index
                break
            if not stack:
                return text[start:index + 1], ""

    body = text[start:end]
    if escaped and body.endswith("\\"):
        body = body[:-1]          # a dangling escape would break the string
    closers = ('"' if in_string else "") + "".join(reversed(stack))
    return body, closers


def _structural_commas(text: str) -> list[int]:
    """Indices of commas that separate JSON members, ignoring string bodies."""
    out: list[int] = []
    in_string = False
    escaped = False
    for index, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == ",":
            out.append(index)
    return out


def _try_close(body: str, closers: str) -> Any:
    import json

    candidate = body if closers.startswith('"') else body.rstrip().rstrip(",")
    return json.loads(candidate + closers)


def _close_truncated_json(body: str, closers: str) -> Any:
    """
    Complete a cut-off JSON value. Truncation lands wherever the token budget
    ran out — mid-string, after a comma, on half a key — so if closing the
    value as-is fails, the tail is dropped back to each earlier member
    boundary in turn until something parses.
    """
    import json

    try:
        return _try_close(body, closers)
    except json.JSONDecodeError:
        pass

    for index in reversed(_structural_commas(body)[-64:]):
        rescanned = _scan_json(body[:index])
        if not rescanned:
            continue
        try:
            return _try_close(*rescanned)
        except json.JSONDecodeError:
            continue
    raise ValueError("truncated JSON could not be closed")


def _parse_json_block_ex(text: str, repair_truncated: bool = False) -> tuple[Any, bool]:
    """
    Tolerant JSON extraction. Models wrap output in fences, prepend "Sure!",
    or get truncated when thinking shares the token budget — none of which
    should cost the user their whole worksheet.

    Returns (value, repaired). `repaired` is True when the value was rebuilt
    from a cut-off response, so callers can prefer a clean retry over it.
    """
    import json

    raw = (text or "").strip()
    if not raw:
        raise ValueError("model returned no text")

    body = _strip_json_fences(raw)
    for attempt in (body, raw):
        try:
            return json.loads(attempt), False
        except (json.JSONDecodeError, ValueError):
            pass

    for attempt in (body, raw):
        scanned = _scan_json(attempt)
        if not scanned:
            continue
        sliced, closers = scanned
        if not closers:
            try:
                return json.loads(sliced), False
            except json.JSONDecodeError:
                # Illegal raw control characters are the usual culprit.
                try:
                    return json.loads(_BARE_CONTROL.sub(" ", sliced)), False
                except json.JSONDecodeError:
                    continue
        if repair_truncated:
            try:
                return _close_truncated_json(
                    _BARE_CONTROL.sub(" ", sliced), closers), True
            except ValueError:
                continue

    raise ValueError(
        f"no JSON object found in {len(raw)} chars: {raw[:160]!r}"
    )


def _parse_json_block(text: str, repair_truncated: bool = False) -> Any:
    """Back-compatible wrapper: the value only."""
    return _parse_json_block_ex(text, repair_truncated=repair_truncated)[0]


def _clean_problems(raw: Any) -> list[dict[str, Any]]:
    """Validate and normalise the model's problem list."""
    if isinstance(raw, dict):
        raw = raw.get("problems", [])
    if not isinstance(raw, list):
        return []

    out: list[dict[str, Any]] = []
    for index, item in enumerate(raw[:60], start=1):   # a page has a bounded
        if not isinstance(item, dict):                 # number of problems
            continue
        answer = str(item.get("answer") or "").strip()[:400]
        steps = item.get("steps")
        steps = [str(s).strip()[:200] for s in steps[:20]
                 if str(s).strip()] if isinstance(steps, list) else []
        out.append({
            "label": str(item.get("label") or index).strip()[:12],
            "reading": str(item.get("reading") or "").strip()[:300],
            "steps": steps,
            "answer": answer,
            "box": _clean_box(item.get("box")),
            # A problem with no answer is unreadable regardless of what the
            # model claimed — the flag drives what the app draws on the page.
            "readable": bool(item.get("readable", True)) and bool(answer),
        })
    return out


def _clean_box(raw: Any) -> dict[str, float] | None:
    """
    Normalise the model's [ymin, xmin, ymax, xmax] (0–1000, top-left origin)
    into fractions of the image. Returns None when the box is missing or
    nonsensical — the app then falls back to flowing answers down the page,
    which is worse but never puts an answer beside the wrong question.
    """
    if not isinstance(raw, (list, tuple)) or len(raw) != 4:
        return None
    try:
        ymin, xmin, ymax, xmax = (float(v) for v in raw)
    except (TypeError, ValueError):
        return None
    if not all(0 <= v <= 1000 for v in (ymin, xmin, ymax, xmax)):
        return None
    if ymax <= ymin or xmax <= xmin:
        return None
    return {
        "y": round(ymin / 1000, 4),
        "x": round(xmin / 1000, 4),
        "height": round((ymax - ymin) / 1000, 4),
        "width": round((xmax - xmin) / 1000, 4),
    }


def solve_worksheet(
    image_bytes: bytes,
    mime_type: str = "image/png",
    math_detail: str = "compact",
) -> list[dict[str, Any]]:
    """
    PEN-15 — solve every problem on a photographed worksheet in one pass.

    Returns a list of {label, reading, steps, answer, readable}. The app places
    each answer beside its own problem, so the result must be structured rather
    than one block of prose.

    Same solve → verify → correct discipline as a single problem, but the
    referee reports per-problem, and only the problems it flags are rewritten.
    A wrong answer on question 2 must not cost the user questions 1 and 3.
    """
    if not image_bytes:
        raise GeminiError("No image supplied.")

    detail = MATH_DETAIL.get((math_detail or "compact").strip().lower(),
                             MATH_DETAIL["compact"]).strip()
    system_prompt = WORKSHEET_SYSTEM_PROMPT + "\n\n" + detail

    image_part = types.Part.from_bytes(data=image_bytes, mime_type=mime_type)
    prompt_part = types.Part.from_text(
        text="Solve every problem on this worksheet.")
    contents = [types.Content(role="user", parts=[image_part, prompt_part])]

    client = _client()
    telemetry.record(telemetry.SOLVE_STARTED)

    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,
                top_p=0.95,
                max_output_tokens=16_000,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # solving every problem on a page is long output AND real reasoning.
                thinking_config=types.ThinkingConfig(thinking_budget=2048),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Worksheet solve failed")
        raise GeminiError(str(exc)) from exc

    try:
        problems = _clean_problems(_parse_json_block(_extract_text(response)))
    except ValueError as exc:
        raise GeminiError(f"Could not read the worksheet: {exc}") from exc
    if not problems:
        raise GeminiError("No problems found on that page.")

    problems = _verify_worksheet(client, image_part, prompt_part,
                                 system_prompt, contents, problems)
    telemetry.record(telemetry.SOLVE_COMPLETED)
    return problems


def _clean_blocks(raw: Any) -> list[dict[str, Any]]:
    """Validate and normalise the model's block list for photo import."""
    if isinstance(raw, dict):
        raw = raw.get("blocks", [])
    if not isinstance(raw, list):
        return []

    out: list[dict[str, Any]] = []
    for item in raw[:80]:                 # a page has a bounded amount of content
        if not isinstance(item, dict):
            continue
        kind = str(item.get("type") or "").strip().lower()
        if kind not in ("text", "math", "image"):
            continue
        if kind == "image":
            box = _clean_box(item.get("box"))
            if box is None:
                # No box means nothing to crop — an undroppable block is
                # worse than a dropped one, so it does not survive.
                continue
            label = str(item.get("label") or "").strip()[:120]
            out.append({"type": "image", "label": label, "box": box})
            continue
        content = str(item.get("content") or "").strip()[:600]
        if not content:
            continue
        out.append({"type": kind, "content": content})
    return out


def import_page(image_bytes: bytes, mime_type: str = "image/png") -> list[dict[str, Any]]:
    """
    Photo import — read an existing paper page and return it as an ordered
    list of blocks the app can rebuild on a live Penpal page.

    Returns [{"type": "text"|"math", "content": "..."}
             | {"type": "image", "label": "...", "box": {x,y,width,height}}, ...]

    Deliberately NOT run through the solve→verify→correct pipeline: this is a
    transcription of what is already on the page, not a computed answer for
    the model to get right or wrong. The equivalent of "verification" here is
    the same one `transcribe_math` relies on — read faithfully, don't invent.
    Content that cannot be faithfully reconstructed as text or math (a
    diagram, a photo, a table) is never forced into fake ink; it comes back
    as an "image" block with a crop box, so the app keeps the real pixels
    instead of a hallucinated re-drawing.

    Uses GEMINI_IMPORT_MODEL when set, so this can be pointed at a different
    model than solving without touching the rest of the pipeline.
    """
    if not image_bytes:
        raise GeminiError("No image supplied.")

    model = (getattr(settings, "GEMINI_IMPORT_MODEL", "") or "").strip() \
        or settings.GEMINI_MODEL

    image_part = types.Part.from_bytes(data=image_bytes, mime_type=mime_type)
    prompt_part = types.Part.from_text(
        text="Read this page and return it as ordered blocks.")
    contents = [types.Content(role="user", parts=[image_part, prompt_part])]

    client = _client()
    try:
        response = client.models.generate_content(
            model=model,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=IMPORT_SYSTEM_PROMPT,
                temperature=0.0,
                top_p=0.95,
                max_output_tokens=16_000,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # transcription is mechanical; the budget belongs to the text.
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Photo import failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)

    try:
        blocks = _clean_blocks(_parse_json_block(_extract_text(response)))
    except ValueError as exc:
        raise GeminiError(f"Could not read that page: {exc}") from exc
    if not blocks:
        raise GeminiError("Nothing readable was found on that page.")
    return blocks


def _clean_illustration(raw: Any, quality: str = "detailed") -> dict[str, Any]:
    """Validate and bound Illustrator's model-authored path plan."""
    if not isinstance(raw, dict):
        raise ValueError("illustration must be a JSON object")

    quality = tracer.normalize_quality(quality)
    profile = tracer.profile_for(quality)
    kind = str(raw.get("kind") or "").strip().lower()
    if kind == "refusal":
        message = str(raw.get("message") or "").strip()[:240]
        return {
            "kind": "refusal",
            "message": message or "I can't draw that.",
        }
    if kind != "strokes":
        raise ValueError("illustration kind must be strokes or refusal")

    source = raw.get("strokes")
    if not isinstance(source, list):
        raise ValueError("illustration strokes must be a list")

    strokes: list[dict[str, Any]] = []
    total_points = 0
    for item in source[:profile.max_strokes]:
        if not isinstance(item, dict) or not isinstance(item.get("points"), list):
            continue
        role = str(item.get("role") or "detail").strip().lower()
        if role not in ("outline", "detail"):
            role = "detail"

        points: list[list[float]] = []
        for pair in item["points"][:profile.max_points_per_stroke]:
            if not isinstance(pair, (list, tuple)) or len(pair) != 2:
                continue
            try:
                x, y = float(pair[0]), float(pair[1])
            except (TypeError, ValueError):
                continue
            if not math.isfinite(x) or not math.isfinite(y):
                continue
            if not 0 <= x <= 1000 or not 0 <= y <= 1000:
                continue
            point = [round(x / 1000, 4), round(y / 1000, 4)]
            if not points or point != points[-1]:
                points.append(point)
        if len(points) < 2:
            continue
        if total_points + len(points) > profile.max_total_points:
            break
        total_points += len(points)
        strokes.append({"role": role, "points": points})

    if not strokes:
        raise ValueError("illustration contains no usable strokes")
    try:
        aspect_ratio = float(raw.get("aspect_ratio") or 1)
    except (TypeError, ValueError):
        aspect_ratio = 1
    if not math.isfinite(aspect_ratio) or not 0.25 <= aspect_ratio <= 4:
        aspect_ratio = 1
    return {
        "kind": "strokes",
        "label": str(raw.get("label") or "illustration").strip()[:120]
            or "illustration",
        "quality": quality,
        "aspect_ratio": round(aspect_ratio, 4),
        "strokes": strokes,
    }


def _illustrate_plan(message: str, quality: str = "quick") -> dict[str, Any]:
    """
    PEN-36 direct path — the model plans ordered stroke geometry itself.

    No image is generated: fast, offline-friendly, and the graceful fallback if
    the trace path fails. Educational and labelled diagrams are allowed; only
    unsafe requests should come back as refusals.
    """
    model = (getattr(settings, "GEMINI_ILLUSTRATOR_MODEL", "") or "").strip() \
        or settings.GEMINI_MODEL
    client = _client()
    try:
        response = _generate(
            client,
            model,
            [types.Content(
                role="user",
                parts=[types.Part.from_text(text=message[:4000])],
            )],
            system_instruction=ILLUSTRATOR_SYSTEM_PROMPT,
            temperature=0.35,
            top_p=0.9,
            # A stroke plan is hundreds of coordinate pairs — one of the
            # longest outputs we ask for, and 8k was not enough for a
            # detailed figure.
            max_output_tokens=24_000,
            response_mime_type="application/json",
            # Plotting geometry is mechanical, not reasoning. Left unset, a
            # thinking-class model spends the whole budget deliberating and
            # returns a few hundred characters of half-finished JSON —
            # exactly the "no JSON object found in 462 chars" failure.
            thinking_config=types.ThinkingConfig(thinking_budget=0),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Illustration planning failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    try:
        return _clean_illustration(
            # A drawing cut off mid-stroke is still a drawing: repair drops
            # the unfinished tail and keeps every complete stroke, which
            # beats refusing to draw anything at all.
            _parse_json_block(_extract_text(response), repair_truncated=True),
            quality=quality,
        )
    except ValueError as exc:
        raise GeminiError(f"Could not draw that: {exc}") from exc


def _gate_illustration(message: str, quality: str) -> dict[str, Any]:
    """
    Decide refuse-vs-draw for the trace path, and — if allowed — write the image
    prompt. Unsafe requests are refused before any image quota is spent;
    educational and labelled diagrams are allowed through.
    """
    model = (getattr(settings, "GEMINI_ILLUSTRATOR_MODEL", "") or "").strip() \
        or settings.GEMINI_MODEL
    client = _client()
    try:
        response = client.models.generate_content(
            model=model,
            contents=[
                types.Content(
                    role="user",
                    parts=[types.Part.from_text(text=message[:4000])],
                )
            ],
            config=types.GenerateContentConfig(
                system_instruction=illustrator_trace_gate_prompt(quality),
                temperature=0.2,
                top_p=0.9,
                # Labelled-diagram image prompts need room; 800 truncates mid-JSON.
                max_output_tokens=2048,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # a short safety judgement.
                thinking_config=types.ThinkingConfig(thinking_budget=512),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Illustration gate failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    text = _extract_text(response)
    try:
        raw = _parse_json_block(text)
    except ValueError:
        logger.warning(
            "Illustration gate returned unparseable output (%d chars); "
            "synthesizing image prompt from the request",
            len(text or ""),
        )
        return _synthesized_illustration_gate(message)

    if not isinstance(raw, dict):
        logger.warning("Illustration gate returned non-object JSON; synthesizing")
        return _synthesized_illustration_gate(message)

    kind = str(raw.get("kind") or "").strip().lower()
    if kind == "refusal":
        message_out = str(raw.get("message") or "").strip()[:240]
        return {"kind": "refusal", "message": message_out or "I can't draw that."}
    prompt = str(raw.get("image_prompt") or "").strip()
    if kind != "image" or not prompt:
        logger.warning(
            "Illustration gate missing image prompt (kind=%r); synthesizing",
            kind,
        )
        return _synthesized_illustration_gate(message)
    aspect_ratio = str(raw.get("aspect_ratio") or "1:1").strip()
    if aspect_ratio not in ("1:1", "4:3", "3:4", "16:9", "9:16"):
        aspect_ratio = "1:1"
    return {
        "kind": "image",
        "label": str(raw.get("label") or "illustration").strip()[:120] or "illustration",
        "image_prompt": prompt[:1500],
        "aspect_ratio": aspect_ratio,
    }


def _synthesized_illustration_gate(message: str) -> dict[str, Any]:
    """
    Keep the trace path alive when the gate model returns empty or broken JSON.
    The image model still gets a usable brief derived from the user's request.
    """
    subject = " ".join(str(message or "").split())[:400] or "the requested subject"
    wants_labels = any(
        token in subject.lower()
        for token in ("label", "labelled", "labeled", "diagram", "schematic")
    )
    label_clause = (
        " Include clear printed black labels next to the named parts, with thin "
        "leader lines and correct spelling."
        if wants_labels
        else " Omit all text and labels."
    )
    return {
        "kind": "image",
        "label": "illustration",
        "image_prompt": (
            f"Clean black-and-white fine-pen line drawing of: {subject}. "
            "Black ink on plain white background, centred with margin, no colour, "
            "no filled regions, no gradients, no border, no decorative frame."
            f"{label_clause}"
        )[:1500],
        "aspect_ratio": "1:1",
    }


def generate_reference_image(
    prompt: str,
    quality: str = "balanced",
    aspect_ratio: str = "1:1",
) -> bytes:
    """Render `prompt` to PNG-ish bytes with the configured image model."""
    quality = tracer.normalize_quality(quality)
    if quality == "detailed":
        model = (
            getattr(settings, "GEMINI_DETAILED_IMAGE_MODEL", "")
            or "gemini-3-pro-image"
        ).strip()
    else:
        model = (
            getattr(settings, "GEMINI_IMAGE_MODEL", "")
            or "gemini-3.1-flash-image"
        ).strip()
    client = _client()
    config: dict[str, Any] = {
        "response_modalities": ["IMAGE"],
        "temperature": 0.4,
    }
    aspect_ratio = (
        aspect_ratio
        if aspect_ratio in ("1:1", "4:3", "3:4", "16:9", "9:16")
        else "1:1"
    )
    if quality == "detailed":
        config["image_config"] = types.ImageConfig(
            aspect_ratio=aspect_ratio, image_size="2K"
        )
    else:
        config["image_config"] = types.ImageConfig(aspect_ratio=aspect_ratio)
    try:
        response = client.models.generate_content(
            model=model,
            contents=[
                types.Content(
                    role="user",
                    parts=[types.Part.from_text(text=prompt[:1500])],
                )
            ],
            config=types.GenerateContentConfig(**config),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Reference image generation failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    for cand in getattr(response, "candidates", None) or []:
        content = getattr(cand, "content", None)
        for part in getattr(content, "parts", None) or []:
            inline = getattr(part, "inline_data", None)
            data = getattr(inline, "data", None) if inline else None
            if data:
                return data
    raise GeminiError("The image model returned no image.")


def _illustrate_trace(message: str, quality: str) -> dict[str, Any]:
    """Trace path — gate → generate reference image → trace to ink strokes."""
    gate = _gate_illustration(message, quality)
    if gate.get("kind") == "refusal":
        return gate
    image_bytes = generate_reference_image(
        gate["image_prompt"],
        quality=quality,
        aspect_ratio=gate["aspect_ratio"],
    )
    raw = tracer.trace(
        image_bytes,
        label=gate.get("label") or "illustration",
        quality=quality,
    )
    if isinstance(raw, dict) and raw.get("kind") == "refusal":
        # An empty/garbled render — degrade honestly instead of inking noise.
        raise GeminiError(raw.get("message") or "Nothing traceable was rendered.")
    return _clean_illustration(raw, quality=quality)


def trace_image(image_bytes: bytes, label: str = "sketch",
                mode: str = "auto", quality: str = "detailed") -> dict[str, Any]:
    """
    PEN-36 (Goal B) — trace a user-provided image into ordered pen strokes.

    Pure on-server computer vision: no model call, so a user's own photo is
    never sent to Gemini. Returns the same stroke/refusal contract as the
    generative path; an untraceable image degrades to an honest refusal rather
    than inking noise.
    """
    quality = tracer.normalize_quality(quality)
    raw = tracer.trace(
        image_bytes,
        label=label or "sketch",
        mode=mode,
        quality=quality,
    )
    if isinstance(raw, dict) and raw.get("kind") == "refusal":
        return {**raw, "quality": quality, "pipeline": "trace"}
    try:
        return {
            **_clean_illustration(raw, quality=quality),
            "pipeline": "trace",
        }
    except ValueError as exc:
        raise GeminiError(f"Could not trace that image: {exc}") from exc


def illustrate(
    message: str,
    mode: str | None = None,
    quality: str = "detailed",
) -> dict[str, Any]:
    """
    PEN-36 — turn a drawing request into ordered pen strokes.

    Quick has the model author stroke geometry directly. Balanced and Detailed
    render the subject with an image model and trace it into ink. Trace degrades
    to a Quick plan on any pipeline failure, so the page still gets a drawing;
    a *refusal* from the gate (unsafe content) is returned as-is.

    `mode` remains as a compatibility shim for older callers.
    """
    message = str(message or "").strip()
    if not message:
        raise GeminiError("A drawing request is required.")

    quality = tracer.normalize_quality(quality)
    if mode == "plan":
        quality = "quick"
    elif mode == "trace" and quality == "quick":
        quality = "balanced"

    if quality == "quick":
        return {
            **_illustrate_plan(message, quality="quick"),
            "pipeline": "plan",
        }

    try:
        return {
            **_illustrate_trace(message, quality),
            "quality": quality,
            "pipeline": "trace",
        }
    except (GeminiError, ValueError):
        logger.warning(
            "Trace illustration failed; falling back to direct plan",
            exc_info=True,
        )
        try:
            return {
                **_illustrate_plan(message, quality="quick"),
                "quality": "quick",
                "pipeline": "plan_fallback",
            }
        except (GeminiError, ValueError) as exc:
            raise GeminiError(
                f"Could not draw that: {exc}"
            ) from exc


SUPPORTED_LANGUAGES = {
    "en-US": "English",
    "es-ES": "Spanish",
    "fr-FR": "French",
    "de-DE": "German",
    "it-IT": "Italian",
    "pt-BR": "Brazilian Portuguese",
}


def _clean_language_turn(raw: Any, language: str) -> dict[str, Any]:
    """Validate a Language Partner reply without stripping its Unicode."""
    if not isinstance(raw, dict):
        raise ValueError("language turn must be a JSON object")
    reply = str(raw.get("reply") or "").strip()[:600]
    if not reply:
        raise ValueError("language turn contains no reply")

    correction = raw.get("correction")
    correction = correction if isinstance(correction, dict) else {}
    try:
        confidence = float(correction.get("confidence") or 0)
    except (TypeError, ValueError):
        confidence = 0
    if not math.isfinite(confidence):
        confidence = 0
    confidence = max(0.0, min(1.0, confidence))

    reason = str(correction.get("reason") or "").strip()[:240]
    corrected = str(correction.get("corrected") or "").strip()[:400]
    skill = str(correction.get("skill") or "").strip()[:120]
    # False corrections are more damaging than missed ones. Require the
    # model's explicit high confidence plus enough content to help.
    found_error = (
        bool(correction.get("found_error"))
        and confidence >= 0.85
        and bool(reason)
        and bool(corrected)
    )
    if not found_error:
        reason = corrected = skill = ""

    return {
        "reply": reply,
        "language": language,
        "correction": {
            "found_error": found_error,
            "reason": reason,
            "corrected": corrected,
            "skill": skill or (f"{language} conversation" if found_error else ""),
            "confidence": round(confidence, 3),
        },
    }


def language_turn(
    message: str,
    language_code: str,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """PEN-37 — converse in the target language and flag one safe correction."""
    message = str(message or "").strip()
    if not message:
        raise GeminiError("A language message is required.")
    language = SUPPORTED_LANGUAGES.get(language_code)
    if not language:
        raise GeminiError("That practice language is not supported.")

    model = (getattr(settings, "GEMINI_LANGUAGE_MODEL", "") or "").strip() \
        or settings.GEMINI_MODEL
    client = _client()
    try:
        response = client.models.generate_content(
            model=model,
            contents=_build_contents(history, message[:4000]),
            config=types.GenerateContentConfig(
                system_instruction=language_partner_prompt(language),
                temperature=0.45,
                top_p=0.9,
                max_output_tokens=3000,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # a reply plus a correction judgement.
                thinking_config=types.ThinkingConfig(thinking_budget=1024),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Language Partner turn failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    try:
        raw = _parse_json_block(_extract_text(response))
        return _clean_language_turn(raw, language)
    except ValueError as exc:
        raise GeminiError(f"Could not continue that conversation: {exc}") from exc


def _clean_debate_turn(raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict):
        raise ValueError("debate turn must be a JSON object")
    counterargument = str(raw.get("counterargument") or "").strip()[:900]
    question = str(raw.get("question") or "").strip()[:240]
    if not counterargument:
        raise ValueError("debate turn contains no counterargument")
    return {
        "counterargument": counterargument,
        "question": question,
    }


def debate_turn(
    message: str,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, str]:
    """PEN-38 — a strongest-good-faith counterpoint, never a grade."""
    message = str(message or "").strip()
    if not message:
        raise GeminiError("An argument is required.")

    model = (getattr(settings, "GEMINI_DEBATE_MODEL", "") or "").strip() \
        or settings.GEMINI_MODEL
    client = _client()
    try:
        response = client.models.generate_content(
            model=model,
            contents=_build_contents(history, message[:4000]),
            config=types.GenerateContentConfig(
                system_instruction=DEBATE_SYSTEM_PROMPT,
                temperature=0.55,
                top_p=0.9,
                max_output_tokens=3000,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # a counterpoint needs some deliberation.
                thinking_config=types.ThinkingConfig(thinking_budget=1024),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Debate Partner turn failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    try:
        return _clean_debate_turn(
            _parse_json_block(_extract_text(response))
        )
    except ValueError as exc:
        raise GeminiError(f"Could not form a counterpoint: {exc}") from exc


def _vision_contents(
    image_part: types.Part,
    prompt: str,
    history: list[dict[str, Any]] | None,
) -> list[types.Content]:
    contents = _build_contents(history, prompt)
    contents[-1] = types.Content(
        role="user",
        parts=[image_part, types.Part.from_text(text=prompt)],
    )
    return contents


def _classify_vision(
    client: genai.Client,
    model: str,
    image_part: types.Part,
    prompt: str,
) -> str:
    try:
        response = client.models.generate_content(
            model=model,
            contents=[types.Content(
                role="user",
                parts=[image_part, types.Part.from_text(text=prompt)],
            )],
            config=types.GenerateContentConfig(
                system_instruction=VISION_CLASSIFIER_PROMPT,
                temperature=0.0,
                max_output_tokens=400,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # a one-word classifier; 400 tokens leaves nothing to think with.
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
        _account(model, response)
        raw = _parse_json_block(_extract_text(response))
        kind = str(raw.get("kind") or "") if isinstance(raw, dict) else ""
        if kind not in ("math", "other"):
            raise ValueError("unknown image kind")
        return kind
    except Exception as exc:  # noqa: BLE001
        logger.exception("Vision classification failed")
        raise GeminiError(f"Could not tell how to read that photo: {exc}") from exc


def vision_turn(
    image_bytes: bytes,
    capability: str,
    message: str = "",
    history: list[dict[str, Any]] | None = None,
    mime_type: str = "image/jpeg",
    math_detail: str = "compact",
    language_code: str = "es-ES",
) -> dict[str, Any]:
    """
    PEN-39 — respond to external visual content through the selected
    capability. This is intentionally separate from PEN-35 transcription.
    """
    if not image_bytes:
        raise GeminiError("No image supplied.")
    capability = (capability or "companion").strip().lower()
    if capability not in ("companion", "mathematician", "language", "debate"):
        raise GeminiError("That capability cannot respond to a photo.")

    defaults = {
        "companion": "What is this? Explain what you can see clearly for a student.",
        "mathematician": "Solve the mathematical problem in this image.",
        "language": "Talk with me in the target language about what is shown here.",
        "debate": "Treat the visible text as the claim and give its strongest counterpoint.",
    }
    prompt = (message or "").strip()[:4000] or defaults[capability]
    image_part = types.Part.from_bytes(data=image_bytes, mime_type=mime_type)

    # Mathematics always uses the existing solve → verify → correct pipeline.
    if capability == "mathematician":
        return {
            "kind": "math",
            "reply": solve_math_image(
                image_bytes,
                mime_type=mime_type,
                history=history,
                math_detail=math_detail,
                question=prompt,
            ),
        }

    model = (getattr(settings, "GEMINI_VISION_MODEL", "") or "").strip() \
        or settings.GEMINI_MODEL
    client = _client()

    # Companion photos may still be maths. Classify first so a visible
    # equation can never receive an unchecked conversational answer.
    if capability == "companion":
        if _classify_vision(client, model, image_part, prompt) == "math":
            return {
                "kind": "math",
                "reply": solve_math_image(
                    image_bytes,
                    mime_type=mime_type,
                    history=history,
                    math_detail=math_detail,
                    question=prompt,
                ),
            }
        system_prompt = (
            build_system_prompt(capability="companion")
            + "\n\n" + VISION_COMPANION_NOTE
        )
        try:
            response = client.models.generate_content(
                model=model,
                contents=_vision_contents(image_part, prompt, history),
                config=types.GenerateContentConfig(
                    system_instruction=system_prompt,
                    temperature=0.5,
                    top_p=0.9,
                    max_output_tokens=2500,
                    # An unset budget lets hidden reasoning consume the whole
                    # allowance and return empty or truncated JSON:
                    # reads an image then answers.
                    thinking_config=types.ThinkingConfig(thinking_budget=1024),
                ),
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("Companion vision failed")
            raise GeminiError(str(exc)) from exc
        _account(model, response)
        reply = _clean_reply(_extract_text(response))
        if not reply:
            raise GeminiError("Nothing readable was found in that photo.")
        return {"kind": "companion", "reply": reply, "trust": "unverified"}

    system_prompt: str
    if capability == "language":
        language = SUPPORTED_LANGUAGES.get(language_code)
        if not language:
            raise GeminiError("That practice language is not supported.")
        system_prompt = language_partner_prompt(language)
    else:
        language = ""
        system_prompt = DEBATE_SYSTEM_PROMPT

    try:
        response = client.models.generate_content(
            model=model,
            contents=_vision_contents(image_part, prompt, history),
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.45 if capability == "language" else 0.55,
                top_p=0.9,
                max_output_tokens=3000,
                response_mime_type="application/json",
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("%s vision failed", capability)
        raise GeminiError(str(exc)) from exc
    _account(model, response)

    try:
        raw = _parse_json_block(_extract_text(response))
        if capability == "language":
            return {
                "kind": "language",
                **_clean_language_turn(raw, language),
            }
        return {
            "kind": "debate",
            **_clean_debate_turn(raw),
            "trust": "perspective",
        }
    except ValueError as exc:
        raise GeminiError(f"Could not read that photo: {exc}") from exc


def _verify_worksheet(client, image_part, prompt_part, system_prompt,
                      contents, problems):
    """Referee pass + one bounded correction. Fails open to the draft."""
    import json

    summary = json.dumps([{"label": p["label"], "reading": p["reading"],
                           "answer": p["answer"]} for p in problems])
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=[types.Content(role="user", parts=[
                image_part,
                types.Part.from_text(text=f"PROPOSED ANSWERS:\n{summary}"),
            ])],
            config=types.GenerateContentConfig(
                system_instruction=WORKSHEET_VERIFIER_PROMPT,
                temperature=0.0,
                max_output_tokens=2000,
                response_mime_type="application/json",
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
        verdict = _parse_json_block(_extract_text(response))
        wrong = verdict.get("wrong", []) if isinstance(verdict, dict) else []
        wrong = [w for w in wrong if isinstance(w, dict) and w.get("label")]
        if not wrong:
            telemetry.record(telemetry.VERIFY_CORRECT)
            return problems

        telemetry.record(telemetry.VERIFY_WRONG)
        reasons = "\n".join(
            f"- {w.get('label')}: {str(w.get('reason'))[:120]}"
            f" (correct answer: {str(w.get('answer'))[:80]})"
            for w in wrong[:20]
        )
        logger.info("Worksheet verifier flagged %d problem(s)", len(wrong))

        retry = contents + [
            types.Content(role="model",
                          parts=[types.Part.from_text(text=summary)]),
            types.Content(role="user", parts=[types.Part.from_text(
                text=WORKSHEET_CORRECTOR_NOTE.format(reasons=reasons))]),
        ]
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=retry,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,
                max_output_tokens=8000,
                response_mime_type="application/json",
            ),
        )
        corrected = _clean_problems(_parse_json_block(_extract_text(response)))
        if corrected:
            telemetry.record(telemetry.VERIFY_CORRECTED)
            return corrected
        return problems
    except Exception as exc:  # noqa: BLE001 — never lose a solved page
        telemetry.record(telemetry.VERIFY_FAILED_OPEN, str(exc))
        logger.exception("Worksheet verification failed; returning draft")
        return problems


def grade_working(
    image_bytes: bytes,
    mime_type: str = "image/png",
) -> dict[str, Any]:
    """
    PEN-16 — mark a student's own working and find the FIRST wrong line.

    Deliberately not a re-solve. Anyone can print the right answer; the useful
    thing a tutor does is point at the line where your reasoning left the
    rails. Everything after a mistake is usually a faithful continuation of a
    wrong value, so reporting later lines too is noise.

    The verifier here is inverted relative to the solver pipeline: it guards
    against FALSE ACCUSATIONS. Telling a student a correct line is wrong costs
    far more trust than missing a slip, so a flagged error is double-checked
    before it is shown, and a disputed flag degrades to "looks right".
    """
    if not image_bytes:
        raise GeminiError("No image supplied.")

    image_part = types.Part.from_bytes(data=image_bytes, mime_type=mime_type)
    prompt_part = types.Part.from_text(
        text="Mark this working. Find the first incorrect line, if any.")

    client = _client()
    telemetry.record(telemetry.SOLVE_STARTED)

    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=[types.Content(role="user",
                                    parts=[image_part, prompt_part])],
            config=types.GenerateContentConfig(
                system_instruction=GRADER_SYSTEM_PROMPT,
                temperature=0.0,
                max_output_tokens=4000,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # judges each step of the working.
                thinking_config=types.ThinkingConfig(thinking_budget=1024),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Grading failed")
        raise GeminiError(str(exc)) from exc

    try:
        raw = _parse_json_block(_extract_text(response))
    except ValueError as exc:
        raise GeminiError(f"Could not read that working: {exc}") from exc
    if not isinstance(raw, dict):
        raise GeminiError("Could not read that working.")

    result = _clean_grade(raw)

    # Only a claimed ERROR needs checking — a "correct" verdict is the safe
    # default and costs nothing if it's a missed slip.
    if result["verdict"] == "error":
        result = _confirm_error(client, image_part, result)

    telemetry.record(telemetry.SOLVE_COMPLETED)
    return result


def _clean_grade(raw: dict[str, Any]) -> dict[str, Any]:
    verdict = str(raw.get("verdict") or "").strip().lower()
    if verdict not in ("correct", "error", "unreadable"):
        verdict = "unreadable"

    line_number = raw.get("line_number")
    try:
        line_number = int(line_number) if line_number is not None else None
        if line_number is not None and not (1 <= line_number <= 200):
            line_number = None
    except (TypeError, ValueError):
        line_number = None

    result = {
        "problem": str(raw.get("problem") or "").strip()[:300],
        "verdict": verdict,
        "line_number": line_number,
        "line_text": str(raw.get("line_text") or "").strip()[:200],
        "box": _clean_box(raw.get("box")),
        "reason": str(raw.get("reason") or "").strip()[:200],
        "correction": str(raw.get("correction") or "").strip()[:200],
        "final_answer": str(raw.get("final_answer") or "").strip()[:300],
    }
    # An "error" with nothing to point at isn't actionable — treat it as a
    # read failure rather than showing the student a vague accusation.
    if result["verdict"] == "error" and not result["reason"]:
        result["verdict"] = "unreadable"
    return result


def _confirm_error(client, image_part, result: dict[str, Any]) -> dict[str, Any]:
    """
    Second opinion on a claimed error. Fails SAFE: if the check breaks, the
    flag is dropped rather than shown, because a false accusation is the
    expensive mistake here.
    """
    claim = (f"The marker says line {result['line_number']} "
             f"(\"{result['line_text']}\") is wrong because: "
             f"{result['reason']}")
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=[types.Content(role="user", parts=[
                image_part,
                types.Part.from_text(text=claim),
            ])],
            config=types.GenerateContentConfig(
                system_instruction=(
                    "You are a merciless referee protecting a student from a "
                    "FALSE ACCUSATION. Read the working in the image and judge "
                    "whether the claimed error is real. A different but valid "
                    "method, unusual notation, or sound skipped algebra is NOT "
                    "an error. Respond with ONLY JSON, no fences: "
                    '{"real": true|false, "reason": "<under 15 words>"}'
                ),
                temperature=0.0,
                max_output_tokens=800,
                response_mime_type="application/json",
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            ),
        )
        verdict = _parse_json_block(_extract_text(response))
        if isinstance(verdict, dict) and verdict.get("real") is False:
            telemetry.record(telemetry.VERIFY_WRONG)
            logger.info("Grader flag withdrawn: %s", verdict.get("reason"))
            return {**result, "verdict": "correct", "line_number": None,
                    "box": None, "reason": "", "correction": ""}
        telemetry.record(telemetry.VERIFY_CORRECT)
        return result
    except Exception as exc:  # noqa: BLE001 — fail SAFE, not open
        telemetry.record(telemetry.VERIFY_FAILED_OPEN, str(exc))
        logger.exception("Grader confirmation failed; withdrawing the flag")
        return {**result, "verdict": "correct", "line_number": None,
                "box": None, "reason": "", "correction": ""}


def stream_math_reply(
    message: str,
    history: list[dict[str, Any]] | None = None,
    math_detail: str = "compact",
):
    """
    PEN-28 — stream the solution, then confirm it.

    Yields dicts:
        {"type": "draft",     "text": "<partial solution so far>"}
        {"type": "final",     "text": "<verified solution>"}
        {"type": "corrected", "text": "<rewritten solution>"}
        {"type": "error",     "message": "..."}

    The ordering is the whole design. Streaming a maths answer straight onto
    paper would be a mistake — ink cannot be unwritten, so a draft that the
    referee later rejects would leave a wrong answer on the page with a
    correction awkwardly beside it.

    So the stream is explicitly a DRAFT: the client shows it forming as a
    faint ghost (the same layer the live preview uses), and only commits real
    ink when "final" or "corrected" arrives. The user gets the responsiveness
    of streaming without the product ever writing something it hasn't checked.
    """
    message = (message or "").strip()
    if not message:
        yield {"type": "error", "message": "Message is empty."}
        return

    system_prompt = build_system_prompt(capability="mathematician",
                                        math_detail=math_detail)
    cas = mathengine.cas_hint(message)
    solver_message = f"{message}\n\n[CAS]\n{cas}" if cas else message
    contents = _build_contents(history, solver_message)
    route = routing.choose(message, cas_hint=cas, math_detail=math_detail)

    client = _client()
    telemetry.record(telemetry.SOLVE_STARTED)

    draft = ""
    try:
        stream = client.models.generate_content_stream(
            model=route.model,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,
                top_p=0.95,
                max_output_tokens=route.max_output_tokens,
            ),
        )
        for chunk in stream:
            piece = getattr(chunk, "text", None) or ""
            if not piece:
                continue
            draft += piece
            yield {"type": "draft",
                   "text": _clean_reply(draft, keep_newlines=True)}
    except Exception as exc:  # noqa: BLE001
        logger.exception("Streaming solve failed")
        yield {"type": "error", "message": str(exc)}
        return

    draft = _clean_reply(draft, keep_newlines=True)
    if not draft:
        yield {"type": "error", "message": "Gemini returned an empty reply."}
        return

    # Same shortcut as the non-streaming path: if SymPy proved the answer and
    # the model reproduced it, there is nothing left to check.
    if route.skip_verification and _agrees_with_cas(draft, route.cas_value):
        telemetry.record(telemetry.VERIFY_CORRECT)
        telemetry.record(telemetry.SOLVE_COMPLETED)
        yield {"type": "final", "text": draft}
        return

    try:
        verdict = _verify_math(
            client, [types.Part.from_text(text=solver_message)], draft)
        if str(verdict.get("verdict")).lower() != "wrong":
            telemetry.record(telemetry.VERIFY_CORRECT)
            telemetry.record(telemetry.SOLVE_COMPLETED)
            yield {"type": "final", "text": draft}
            return

        telemetry.record(telemetry.VERIFY_WRONG)
        reason = str(verdict.get("reason") or "final answer incorrect")[:300]
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=contents + [
                types.Content(role="model",
                              parts=[types.Part.from_text(text=draft)]),
                types.Content(role="user", parts=[types.Part.from_text(
                    text=MATH_CORRECTOR_NOTE.format(reason=reason))]),
            ],
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.0,
                max_output_tokens=4000,
            ),
        )
        _account(settings.GEMINI_MODEL, response)
        corrected = _clean_reply(_extract_text(response), keep_newlines=True)
        telemetry.record(telemetry.VERIFY_CORRECTED)
        telemetry.record(telemetry.SOLVE_COMPLETED)
        # The client replaces the ghost entirely — the rejected draft is never
        # committed to the page.
        yield {"type": "corrected", "text": corrected or draft}
    except Exception as exc:  # noqa: BLE001 — fail open to the draft
        telemetry.record(telemetry.VERIFY_FAILED_OPEN, str(exc))
        telemetry.record(telemetry.SOLVE_COMPLETED)
        logger.exception("Streaming verification failed; returning draft")
        yield {"type": "final", "text": draft}


def practice_problem(
    topic: str,
    mistake: str = "",
    difficulty: str = "same",
    domain: str = "math",
) -> dict[str, Any]:
    """
    PEN-19 — one practice problem targeting a specific past mistake.

    Deliberately narrow. A generic "give me an algebra question" is easy and
    nearly useless; the value is in aiming at the exact misunderstanding the
    grader already caught, days later, when it has had a chance to fade.
    """
    topic = (topic or "").strip()[:200]
    if not topic:
        raise GeminiError("No topic to practise.")

    difficulty = (difficulty or "same").strip().lower()
    if difficulty not in ("easier", "same", "harder"):
        difficulty = "same"
    domain = "language" if (domain or "").strip().lower() == "language" else "math"

    prompt = f"Topic: {topic}\nDifficulty: {difficulty}"
    if mistake:
        prompt += f"\nWhat they got wrong last time: {mistake.strip()[:300]}"

    client = _client()
    try:
        response = client.models.generate_content(
            model=settings.GEMINI_MODEL,
            contents=[types.Content(role="user",
                                    parts=[types.Part.from_text(text=prompt)])],
            config=types.GenerateContentConfig(
                system_instruction=(
                    LANGUAGE_PRACTICE_SYSTEM_PROMPT
                    if domain == "language" else PRACTICE_SYSTEM_PROMPT
                ),
                # A little warmth here: identical practice problems every time
                # would be recognisable rather than instructive.
                temperature=0.6,
                max_output_tokens=2000,
                response_mime_type="application/json",
                # An unset budget lets hidden reasoning consume the whole
                # allowance and return empty or truncated JSON:
                # writes one short problem.
                thinking_config=types.ThinkingConfig(thinking_budget=512),
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Practice generation failed")
        raise GeminiError(str(exc)) from exc

    _account(settings.GEMINI_MODEL, response)
    try:
        raw = _parse_json_block(_extract_text(response))
    except ValueError as exc:
        raise GeminiError(f"Could not write a practice problem: {exc}") from exc
    if not isinstance(raw, dict):
        raise GeminiError("Could not write a practice problem.")

    problem = str(raw.get("problem") or "").strip()[:400]
    answer = str(raw.get("answer") or "").strip()[:200]
    if not problem or not answer:
        raise GeminiError("Could not write a practice problem.")

    return {
        "problem": problem,
        "answer": answer,
        "hint": str(raw.get("hint") or "").strip()[:200],
        "skill": str(raw.get("skill") or topic).strip()[:80],
    }


_INTERACTIVE_MAX_HTML = 120_000
# Height bounds for a generated block, in points. The ceiling is a default,
# not a law: a section that knows the box it will occupy raises it, because
# clamping a full-width simulator to 520pt is what forces a manual resize.
_INTERACTIVE_MIN_HEIGHT = 180
_INTERACTIVE_MAX_HEIGHT = 520
_INTERACTIVE_ABSOLUTE_MAX_HEIGHT = 900
_INTERACTIVE_CAPABILITIES = {
    "companion", "mathematician", "illustrator", "language", "debate", "interactive",
}
_INTERACTIVE_FORBIDDEN_MARKUP = re.compile(
    r"<\s*/?\s*(?:html|head|body|object|embed|base|meta)\b|<!doctype",
    re.IGNORECASE,
)
_INTERACTIVE_NATIVE_BRIDGE = re.compile(
    r"(?:window\s*\.\s*)?webkit\s*\.\s*messageHandlers",
    re.IGNORECASE,
)
_INTERACTIVE_FORBIDDEN_SCHEME = re.compile(
    # Match executable/privileged URL schemes, not harmless labels such as
    # "JavaScript: ready" or "Penpal: permission denied".
    r"(?:file|penpal)\s*://"
    r"|javascript\s*:(?!\s)"
    r"|data\s*:\s*text/html",
    re.IGNORECASE,
)
_INTERACTIVE_URL = re.compile(
    r"\b(?:https?|wss?)://[^\s\"'<>`]+",
    re.IGNORECASE,
)
_INTERACTIVE_ALLOWED_CAPABILITIES = {
    "camera", "microphone", "location",
    "clipboard.read", "clipboard.write",
    "files.read", "files.write", "downloads", "storage.large",
}
_INTERACTIVE_DEPENDENCY_KINDS = {
    "script", "module", "style", "wasm", "worker", "python",
}


def _public_runtime_host(raw: Any) -> str | None:
    """Return a normalized public host, rejecting app/local network targets."""
    value = str(raw or "").strip().lower().rstrip(".")
    if not value:
        return None
    parsed = urlparse(value if "://" in value else f"https://{value}")
    host = (parsed.hostname or "").strip().lower().rstrip(".")
    if not host or host == "localhost" or host.endswith((".local", ".internal")):
        return None
    try:
        address = ipaddress.ip_address(host)
        return host if address.is_global else None
    except ValueError:
        pass
    if "." not in host:
        return None
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        return None
    if len(host) > 253 or not all(
        re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in host.split(".")
    ):
        return None
    return host


def _clean_interactive_manifest(raw: Any, source: str) -> dict[str, Any]:
    raw = raw if isinstance(raw, dict) else {}
    domains: dict[str, str] = {}
    for item in (raw.get("domains") or [])[:24]:
        if not isinstance(item, dict):
            continue
        host = _public_runtime_host(item.get("host"))
        if not host:
            continue
        reason = " ".join(str(item.get("reason") or "Access this domain.").split())
        domains[host] = reason[:160]

    dependencies: list[dict[str, str]] = []
    for item in (raw.get("dependencies") or [])[:24]:
        if not isinstance(item, dict):
            continue
        url = str(item.get("url") or "").strip()[:1500]
        parsed = urlparse(url)
        host = _public_runtime_host(url)
        kind = str(item.get("kind") or "script").strip().lower()
        if (parsed.scheme != "https" or not host or parsed.username
                or parsed.password or kind not in _INTERACTIVE_DEPENDENCY_KINDS):
            continue
        clean = {"url": url, "kind": kind}
        integrity = str(item.get("integrity") or "").strip()[:200]
        if integrity:
            clean["integrity"] = integrity
        dependencies.append(clean)
        domains.setdefault(host, f"Load the declared {kind} dependency.")

    # A missing declaration never becomes a silent network grant. Discover
    # literal public URLs and put their hosts in the consent manifest.
    for match in _INTERACTIVE_URL.findall(html_lib.unescape(source)):
        parsed = urlparse(match.rstrip(").,;"))
        if parsed.scheme in {"http", "ws"}:
            raise GeminiError("Interactive output used insecure HTTP.")
        host = _public_runtime_host(match)
        if not host:
            raise GeminiError("Interactive output referenced a local or private host.")
        domains.setdefault(host, "Access an external resource used by this block.")

    capabilities: list[dict[str, str]] = []
    seen_capabilities: set[str] = set()
    for item in (raw.get("capabilities") or [])[:16]:
        if not isinstance(item, dict):
            continue
        capability = str(item.get("id") or "").strip().lower()
        if capability not in _INTERACTIVE_ALLOWED_CAPABILITIES:
            continue
        if capability in seen_capabilities:
            continue
        seen_capabilities.add(capability)
        reason = " ".join(str(item.get("reason") or "Use this capability.").split())
        capabilities.append({"id": capability, "reason": reason[:160]})

    return {
        "version": 1,
        "domains": [
            {"host": host, "reason": reason}
            for host, reason in sorted(domains.items())
        ],
        "capabilities": capabilities,
        "dependencies": dependencies,
    }


def _clean_interactive_result(raw: Any, max_height: int = 0) -> dict[str, Any]:
    """Validate model output before it reaches the isolated web runtime."""
    if not isinstance(raw, dict):
        raise GeminiError("Interactive output was not an object.")

    source = str(raw.get("html") or "").strip()
    if not source or "<" not in source:
        raise GeminiError("Interactive output did not contain HTML.")
    if len(source) > _INTERACTIVE_MAX_HTML:
        raise GeminiError("Interactive output was too large.")

    # Decode entities for validation because WebKit will decode them too.
    inspected = html_lib.unescape(source)
    if _INTERACTIVE_FORBIDDEN_MARKUP.search(inspected):
        raise GeminiError("Interactive output used a forbidden HTML element.")
    if _INTERACTIVE_NATIVE_BRIDGE.search(inspected):
        raise GeminiError(
            "Interactive output used window.webkit; use window.penpal.runtime instead."
        )
    if _INTERACTIVE_FORBIDDEN_SCHEME.search(inspected):
        raise GeminiError("Interactive output used a forbidden local or executable URL.")

    try:
        preferred_height = int(raw.get("preferred_height") or 320)
    except (TypeError, ValueError):
        preferred_height = 320
    # A block built for a known box may legitimately be taller than the
    # standalone default: a full-width simulator squeezed into 520pt is the
    # thing the user then has to resize by hand.
    ceiling = max(
        _INTERACTIVE_MIN_HEIGHT,
        min(_INTERACTIVE_ABSOLUTE_MAX_HEIGHT,
            int(max_height or _INTERACTIVE_MAX_HEIGHT)),
    )

    reply = _clean_reply(str(raw.get("reply") or "I made an interactive block."))
    title = " ".join(_fold_for_ink(str(raw.get("title") or "Interactive")).split())
    result = {
        "reply": reply[:180] or "I made an interactive block.",
        "title": title[:80] or "Interactive",
        "html": source,
        "preferred_height": min(ceiling, max(_INTERACTIVE_MIN_HEIGHT,
                                             preferred_height)),
        "manifest": _clean_interactive_manifest(raw.get("manifest"), source),
    }
    return result


# Retry ladder for interactive builds. Truncation is the dominant failure —
# the model spends the allowance on hidden reasoning plus a large single-file
# app and never reaches the closing brace — so each retry buys output room and
# takes it back from thinking. gemini-2.5-flash caps output at 65,535 tokens;
# `_generate` clamps automatically if a configured model allows less.
_INTERACTIVE_BUDGETS = (
    {"max_output_tokens": 32_000, "thinking_budget": 2048},
    {"max_output_tokens": 48_000, "thinking_budget": 512},
    {"max_output_tokens": 64_000, "thinking_budget": 0},
)

_TRUNCATED_BUILD_FEEDBACK = (
    "Your previous response was empty, cut off before the closing brace, or "
    "otherwise malformed. Return ONE complete JSON object and nothing else. "
    "Keep the fragment well under 60,000 characters: prefer a compact, "
    "well-factored build over a long one, drop optional flourishes, avoid "
    "large inline data/base64/SVG paths, and finish the JSON."
)


def _interactive_budget(attempt: int) -> dict[str, int]:
    return _INTERACTIVE_BUDGETS[min(attempt, len(_INTERACTIVE_BUDGETS) - 1)]


def _seal_fragment(source: str) -> str:
    """
    Close tags a truncated build left open.

    A salvaged fragment is only ever used when every clean attempt failed,
    but an unterminated <script> would dump raw source onto the page. Closing
    it costs nothing and turns garbage into a partial, readable block.
    """
    # Drop a tag the cut landed inside ("...<div class=") — a half-written
    # tag swallows whatever follows it.
    last_open = source.rfind("<")
    if last_open > source.rfind(">"):
        source = source[:last_open]
    for tag in ("script", "style"):
        opened = len(re.findall(rf"<{tag}\b[^>]*>", source, re.I))
        closed = len(re.findall(rf"</{tag}\s*>", source, re.I))
        if opened > closed:
            source += f"</{tag}>" * (opened - closed)
    return source.rstrip()


def _needs_agentic_interactive_build(message: str) -> bool:
    """Route genuinely complex browser apps through a bounded review loop."""
    lower = message.lower()
    signals = (
        "3d", "webgl", "webgpu", "physics", "pendulum", "simulation",
        "game", "multiplayer", "neural", "classifier", "editor", "dashboard",
        "pyodide", "python", "webassembly", "worker", "real-time", "realtime",
        "multiple scenes", "decision boundary", "trajectory",
    )
    score = sum(1 for signal in signals if signal in lower)
    return score >= 2 or len(message) >= 420


def _review_interactive_candidate(
    client: genai.Client,
    message: str,
    candidate: dict[str, Any],
) -> list[str]:
    """Return concrete repair issues; malformed review fails open."""
    review_payload = json.dumps(candidate, ensure_ascii=False)
    last_error = ""
    for attempt in range(2):
        try:
            response = _generate(
                client,
                settings.GEMINI_MODEL,
                [types.Content(
                    role="user",
                    parts=[types.Part.from_text(
                        text=f"USER REQUEST:\n{message}\n\nCANDIDATE:\n{review_payload}"
                    )],
                )],
                system_instruction=INTERACTIVE_REVIEW_PROMPT,
                temperature=0.0,
                max_output_tokens=4000,
                response_mime_type="application/json",
                # The review is tiny and deterministic. Disabling visible
                # thinking prevents the model consuming its whole response
                # budget before emitting the verdict.
                thinking_config=types.ThinkingConfig(thinking_budget=0),
            )
            _account(settings.GEMINI_MODEL, response)
            raw = _parse_json_block(_extract_text(response), repair_truncated=True)
            if not isinstance(raw, dict) or str(raw.get("verdict")) != "repair":
                return []
            issues = raw.get("issues")
            if not isinstance(issues, list):
                return []
            return [" ".join(str(issue).split())[:300]
                    for issue in issues[:8] if str(issue).strip()]
        except Exception as exc:  # noqa: BLE001 — valid build remains usable
            last_error = str(exc)
            if attempt == 0:
                continue
    logger.warning(
        "Interactive quality review unavailable after retry; "
        "using the validated candidate: %s",
        last_error,
    )
    return []


def generate_interactive_block(
    message: str,
    history: list[dict[str, Any]] | None = None,
    capability: str = "interactive",
    language: str = "",
    math_detail: str = "compact",
    max_height: int = 0,
) -> dict[str, Any]:
    """Generate a browser block, using a bounded agent loop when warranted."""
    message = (message or "").strip()
    if not message:
        raise GeminiError("Message is empty.")

    capability = (capability or "interactive").strip().lower()
    if capability not in _INTERACTIVE_CAPABILITIES:
        capability = "interactive"
    context = (
        f"[Specialty: {capability}]\n"
        f"[Language: {(language or 'not specified').strip()[:40]}]\n"
        f"[Math detail: {(math_detail or 'compact').strip()[:20]}]\n"
        f"{message}"
    )
    client = _client()
    base_contents = _build_contents(history, context)
    agentic = _needs_agentic_interactive_build(message)
    feedback: list[str] = []
    # Keep spare generations for empty/truncated model responses. Complex
    # builds get another pass for the actual reviewer-directed repair.
    attempts = 4 if agentic else 3
    candidate: dict[str, Any] | None = None
    salvage: dict[str, Any] | None = None
    salvaged = False
    last_error = ""

    for attempt in range(attempts):
        contents = list(base_contents)
        if feedback:
            contents.append(types.Content(
                role="user",
                parts=[types.Part.from_text(
                    text="Repair the build and return the complete JSON again.\n"
                         + "\n".join(f"- {issue}" for issue in feedback)
                )],
            ))
        budget = _interactive_budget(attempt)
        try:
            response = _generate(
                client,
                settings.GEMINI_MODEL,
                contents,
                system_instruction=INTERACTIVE_SYSTEM_PROMPT,
                temperature=0.35 if attempt == 0 else 0.2,
                top_p=0.9,
                # Thinking-class Gemini models spend this same budget on
                # hidden reasoning. A complex app can otherwise consume the
                # whole allowance before emitting the first JSON token, so
                # each retry buys more room and thinks less.
                max_output_tokens=budget["max_output_tokens"],
                response_mime_type="application/json",
                thinking_config=types.ThinkingConfig(
                    thinking_budget=budget["thinking_budget"]),
            )
            _account(settings.GEMINI_MODEL, response)
            text = _extract_text(response)
            if not text.strip():
                raise GeminiError(_empty_response_reason(response))
            raw, repaired = _parse_json_block_ex(text, repair_truncated=True)
            cut_off = repaired or _was_truncated(response)
            if cut_off and isinstance(raw, dict) and raw.get("html"):
                raw = {**raw, "html": _seal_fragment(str(raw["html"]))}
            cleaned = _clean_interactive_result(raw, max_height=max_height)
        except GeminiError as exc:
            last_error = str(exc)
            if candidate is not None:
                logger.exception("Interactive repair failed; keeping valid draft")
                break
            if attempt + 1 < attempts:
                logger.warning("Retrying invalid interactive build: %s", exc)
                feedback = [f"The previous build was invalid: {exc}"]
                continue
            if salvage is None:
                raise
            logger.warning("Using salvaged truncated build: %s", exc)
            break
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
            if candidate is not None:
                logger.exception("Interactive repair failed; keeping valid draft")
                break
            if attempt + 1 < attempts:
                logger.warning("Retrying malformed interactive build: %s", exc)
                feedback = [_TRUNCATED_BUILD_FEEDBACK]
                continue
            if salvage is None:
                logger.exception("Interactive block generation failed")
                raise GeminiError(
                    f"Gemini returned malformed interactive output: {exc}"
                ) from exc
            logger.warning("Using salvaged truncated build: %s", exc)
            break

        if cut_off:
            # It parses, but the model was cut off mid-app: keep it only as a
            # floor and spend the remaining attempts on a build that finished.
            if salvage is None:
                salvage = cleaned
            if attempt + 1 < attempts:
                logger.warning(
                    "Interactive build was truncated (%s); retrying with more room",
                    _finish_reason(response) or "repaired JSON",
                )
                feedback = [_TRUNCATED_BUILD_FEEDBACK]
                continue
            logger.warning("Every interactive build was truncated; using the last one")

        candidate = cleaned
        salvaged = cut_off
        if not agentic:
            break
        feedback = _review_interactive_candidate(client, message, candidate)
        if not feedback:
            break

    if candidate is None:
        candidate, salvaged = salvage, True
    if candidate is None:
        raise GeminiError(
            f"Gemini returned no interactive build. {last_error}".strip())
    candidate["build_mode"] = "agentic" if agentic else "single"
    candidate["iterations"] = attempt + 1
    # True when the block came back cut off: it renders, but the client can
    # tell the user it is partial and offer a rebuild.
    candidate["salvaged"] = salvaged
    return candidate


def repair_interactive_block(
    html: str,
    manifest: dict[str, Any] | None,
    diagnostics: list[dict[str, Any]] | None,
    title: str = "Interactive Block",
) -> dict[str, Any]:
    """Investigate and repair one failing block with a bounded agent loop."""
    html = str(html or "").strip()
    if not html or len(html) > _INTERACTIVE_MAX_HTML:
        raise GeminiError("Interactive source is empty or too large.")

    safe_diagnostics: list[dict[str, Any]] = []
    for item in (diagnostics or [])[:6]:
        if not isinstance(item, dict):
            continue
        safe_diagnostics.append({
            "kind": " ".join(str(item.get("kind") or "runtime").split())[:40],
            "message": " ".join(str(item.get("message") or "Unknown failure").split())[:400],
            "source": str(item.get("source") or "").split("?")[0][:300],
            "line": item.get("line") if isinstance(item.get("line"), int) else None,
            "column": item.get("column") if isinstance(item.get("column"), int) else None,
        })
    if not safe_diagnostics:
        raise GeminiError("No runtime diagnostics were supplied.")

    safe_manifest = _clean_interactive_manifest(manifest, html)
    payload = json.dumps({
        "title": str(title or "Interactive Block")[:80],
        "manifest": safe_manifest,
        "diagnostics": safe_diagnostics,
        "html": html,
    }, ensure_ascii=False)
    base_contents = [types.Content(
        role="user",
        parts=[types.Part.from_text(
            text="Investigate and repair this failing interactive block:\n" + payload
        )],
    )]
    client = _client()
    candidate: dict[str, Any] | None = None
    salvage: dict[str, Any] | None = None
    salvage_diagnosis = ""
    diagnosis = ""
    feedback: list[str] = []
    attempts = 3

    for attempt in range(attempts):
        contents = list(base_contents)
        if feedback:
            contents.append(types.Content(
                role="user",
                parts=[types.Part.from_text(
                    text="The repair review found these remaining problems. "
                         "Return the corrected complete JSON:\n"
                         + "\n".join(f"- {issue}" for issue in feedback)
                )],
            ))
        budget = _interactive_budget(attempt)
        try:
            response = _generate(
                client,
                settings.GEMINI_MODEL,
                contents,
                system_instruction=(
                    INTERACTIVE_SYSTEM_PROMPT + "\n\n" + INTERACTIVE_REPAIR_PROMPT
                ),
                temperature=0.15,
                top_p=0.85,
                max_output_tokens=budget["max_output_tokens"],
                response_mime_type="application/json",
                thinking_config=types.ThinkingConfig(
                    thinking_budget=min(3072, budget["thinking_budget"] + 1024)),
            )
            _account(settings.GEMINI_MODEL, response)
            text = _extract_text(response)
            if not text.strip():
                raise GeminiError(_empty_response_reason(response))
            raw, repaired = _parse_json_block_ex(text, repair_truncated=True)
            cut_off = repaired or _was_truncated(response)
            if cut_off and isinstance(raw, dict) and raw.get("html"):
                raw = {**raw, "html": _seal_fragment(str(raw["html"]))}
            cleaned = _clean_interactive_result(raw)
            found = ""
            if isinstance(raw, dict):
                found = " ".join(
                    str(raw.get("diagnosis") or raw.get("reply") or "").split()
                )[:400]
            if cut_off and attempt + 1 < attempts:
                # A half-written repair is worse than the bug it replaces;
                # hold it as a floor and try again with more output room.
                if salvage is None:
                    salvage, salvage_diagnosis = cleaned, found
                logger.warning("Interactive repair was truncated; retrying")
                feedback = [_TRUNCATED_BUILD_FEEDBACK]
                continue
            candidate, diagnosis = cleaned, found
        except Exception as exc:  # noqa: BLE001
            if candidate is not None:
                logger.exception("Interactive repair revision failed; keeping first repair")
                break
            if attempt + 1 < attempts:
                logger.warning("Retrying malformed interactive repair: %s", exc)
                feedback = [
                    "The previous repair was empty, malformed, or failed "
                    "validation. " + _TRUNCATED_BUILD_FEEDBACK
                ]
                continue
            if salvage is not None:
                logger.warning("Using salvaged truncated repair: %s", exc)
                candidate, diagnosis = salvage, salvage_diagnosis
                break
            logger.exception("Interactive self-healing failed")
            if isinstance(exc, GeminiError):
                raise
            raise GeminiError(
                f"Gemini could not produce a valid repair: {exc}") from exc

        feedback = _review_interactive_candidate(
            client,
            "Repair the supplied runtime failures without changing requested behavior.",
            candidate,
        )
        if not feedback:
            break

    if candidate is None:
        candidate, diagnosis = salvage, diagnosis or salvage_diagnosis
    if candidate is None:
        raise GeminiError("Gemini returned no valid repair.")
    candidate["diagnosis"] = diagnosis or "Repaired the reported runtime failure."
    candidate["build_mode"] = "self_heal"
    candidate["iterations"] = attempt + 1
    return candidate


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
        return _math_reply(client, history, message, system_prompt,
                           math_detail=math_detail)

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
                # Generous ON PURPOSE. Thinking-class models (gemini-2.5+ /
                # 3.x) spend output tokens on internal reasoning BEFORE the
                # visible text; a tight cap (this was 220) returns an EMPTY
                # reply → 503 "Gemini returned an empty reply." The prompt
                # already constrains the note to ~45 words, so the cap only
                # needs to cover reasoning headroom, not limit prose length.
                max_output_tokens=2048,
            ),
        )
    except Exception as exc:  # noqa: BLE001 — surface as API error
        logger.exception("Gemini generate_content failed")
        raise GeminiError(str(exc)) from exc

    cleaned = _clean_reply(_extract_text(response), keep_newlines=False)
    if not cleaned:
        raise GeminiError("Gemini returned an empty reply.")
    return cleaned


# ---------------------------------------------------------------------------
# PEN-40 — the arranger: compose a whole page from several specialists
# ---------------------------------------------------------------------------

_ARRANGER_TEMPLATES = {
    "modular-grid", "cornell", "two-column", "path", "radial", "skyscraper",
}
_ARRANGER_ROLES = {
    "title", "diagram", "explanation", "example", "animation",
    "summary", "reference", "checklist", "callout",
}
_ARRANGER_CAPABILITIES = {
    "illustrator", "companion", "mathematician", "interactive",
    "language", "debate",
}
_ARRANGER_BLOCKS = {"ink", "diagram", "interactive", "table", "checklist"}
_ARRANGER_SPANS = {"full", "half", "third"}
_ARRANGER_ADJACENCY = {"below", "beside"}

# A page is a page. These caps bound cost and stop the planner turning one
# idea into a wall of fragments.
_ARRANGER_MAX_SECTIONS = 7
_ARRANGER_MAX_INTERACTIVE = 2
# Sections run concurrently; an interactive build is the slow one, so the
# pool only needs to cover a realistic page.
_ARRANGER_WORKERS = 6


def _clean_arranger_plan(raw: Any) -> dict[str, Any]:
    """Validate the planner's composition plan into something layout-safe."""
    if not isinstance(raw, dict):
        raise GeminiError("The arranger returned no plan.")

    sections: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    interactive_count = 0

    for index, item in enumerate(raw.get("sections") or [], start=1):
        if not isinstance(item, dict):
            continue
        if len(sections) >= _ARRANGER_MAX_SECTIONS:
            break

        prompt = " ".join(str(item.get("prompt") or "").split())[:1200]
        if not prompt:
            continue        # a specialist cannot work from nothing

        identifier = str(item.get("id") or f"s{index}").strip()[:24]
        if not identifier or identifier in seen_ids:
            identifier = f"s{index}"
        seen_ids.add(identifier)

        capability = str(item.get("capability") or "companion").strip().lower()
        if capability not in _ARRANGER_CAPABILITIES:
            capability = "companion"

        block = str(item.get("block") or "ink").strip().lower()
        if block not in _ARRANGER_BLOCKS:
            block = "ink"

        # Keep capability and block honest with each other: an illustrator
        # section is a drawing, and only the interactive specialist can fill
        # a live block. A mismatch here would strand content in a block that
        # cannot render it.
        if capability == "illustrator":
            block = "diagram"
        elif block == "interactive" and capability != "interactive":
            capability = "interactive"
        elif capability == "interactive" and block != "interactive":
            block = "interactive"

        if block == "interactive":
            interactive_count += 1
            if interactive_count > _ARRANGER_MAX_INTERACTIVE:
                # Demote the surplus rather than dropping the content.
                capability, block = "companion", "ink"

        role = str(item.get("role") or "explanation").strip().lower()
        if role not in _ARRANGER_ROLES:
            role = "explanation"

        span = str(item.get("span") or "full").strip().lower()
        if span not in _ARRANGER_SPANS:
            span = "full"

        adjacency = str(item.get("adjacency") or "").strip().lower()
        anchor = str(item.get("anchor") or "").strip()[:24]
        if adjacency not in _ARRANGER_ADJACENCY or not anchor:
            anchor, adjacency = "", ""

        sections.append({
            "id": identifier,
            "role": role,
            "capability": capability,
            "block": block,
            "prompt": prompt,
            "span": span,
            "priority": len(sections) + 1,
            "anchor": anchor,
            "adjacency": adjacency,
        })

    if not sections:
        raise GeminiError("The arranger planned no sections.")

    # An anchor pointing at a dropped or later section would make the layout
    # unsolvable on the device, so resolve it here where it is cheap.
    valid = {section["id"]: section["priority"] for section in sections}
    for section in sections:
        anchor = section["anchor"]
        if anchor not in valid or valid[anchor] >= section["priority"]:
            section["anchor"], section["adjacency"] = "", ""

    template = str(raw.get("template") or "modular-grid").strip().lower()
    if template not in _ARRANGER_TEMPLATES:
        template = "modular-grid"

    title = " ".join(_fold_for_ink(str(raw.get("title") or "Notes")).split())
    reply = _clean_reply(str(raw.get("reply") or "I arranged this page."))
    return {
        "title": title[:60] or "Notes",
        "template": template,
        "reply": reply[:180] or "I arranged this page.",
        "sections": sections,
    }


def plan_page(
    message: str,
    history: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Decompose one request into a validated composition plan."""
    message = (message or "").strip()
    if not message:
        raise GeminiError("Message is empty.")

    client = _client()
    contents = _build_contents(history, message)
    last_error = ""
    for attempt in range(3):
        try:
            response = _generate(
                client,
                settings.GEMINI_MODEL,
                contents,
                system_instruction=ARRANGER_SYSTEM_PROMPT,
                temperature=0.4 if attempt == 0 else 0.2,
                max_output_tokens=8_000,
                response_mime_type="application/json",
                # Planning is short and structural. Spending the budget on
                # visible reasoning is what empties the response.
                thinking_config=types.ThinkingConfig(thinking_budget=1024),
            )
            _account(settings.GEMINI_MODEL, response)
            text = _extract_text(response)
            if not text.strip():
                raise GeminiError(_empty_response_reason(response))
            return _clean_arranger_plan(
                _parse_json_block(text, repair_truncated=True))
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
            if attempt + 1 < 3:
                logger.warning("Retrying arranger plan: %s", exc)
                continue
            logger.exception("Arranger planning failed")
            raise GeminiError(
                f"Could not plan that page: {last_error}") from exc
    raise GeminiError("Could not plan that page.")


# A typical iPad writing column, used when the client does not say. Only the
# device knows the real width, so this is a fallback and not a default worth
# tuning.
_ARRANGER_ASSUMED_PAGE_WIDTH = 740
_ARRANGER_GUTTER = 24

# How tall a section of each span may reasonably be, in points. A full-width
# simulator needs real room; a third-width card does not.
_ARRANGER_HEIGHT_BY_SPAN = {"full": 560, "half": 420, "third": 340}

# Matches PageMetrics.minimumColumnWidth on the device: narrower than this and
# the compositor collapses the band instead of shipping it unreadable.
_ARRANGER_MIN_COLUMN_WIDTH = 190


def _section_box(span: str, page_width: float) -> tuple[int, int]:
    """
    The approximate region a section will occupy, in points.

    This is the whole answer to "why did the block come out the wrong size".
    A specialist that does not know its box designs for an imaginary viewport
    — usually a wide desktop one — and the result arrives needing a manual
    resize. Telling it the real width up front costs nothing and removes the
    guess.

    Approximate on purpose: the device solves the true layout, and a section
    can still be promoted to full width. The hint sets the PROPORTIONS the
    specialist designs for, which is what actually matters.
    """
    width = max(240.0, float(page_width or _ARRANGER_ASSUMED_PAGE_WIDTH))

    # Mirror PageComposer.normalise exactly. The device widens a span rather
    # than ship an unreadably narrow column, so a server that ignored this
    # would promise a specialist 230 points when it will actually be handed
    # 358 — a lie in the one direction that produces a wrong-shaped block.
    if width >= 900:
        allowed = 3
    elif width >= 460:
        allowed = 2
    else:
        allowed = 1
    while allowed > 1 and (width - _ARRANGER_GUTTER * (allowed - 1)) / allowed \
            < _ARRANGER_MIN_COLUMN_WIDTH:
        allowed -= 1

    if allowed == 1:
        span = "full"
    elif allowed == 2 and span == "third":
        span = "half"

    fraction = {"full": 1.0, "half": 0.5, "third": 1.0 / 3.0}.get(span, 1.0)
    columns = round(1 / fraction)
    usable = width - _ARRANGER_GUTTER * (columns - 1)
    return (int(usable * fraction),
            _ARRANGER_HEIGHT_BY_SPAN.get(span, _ARRANGER_MAX_SECTION_HEIGHT))


_ARRANGER_MAX_SECTION_HEIGHT = 560


def _render_section(
    section: dict[str, Any],
    language: str,
    math_detail: str,
    illustration_quality: str,
    page_width: float = 0,
) -> dict[str, Any]:
    """
    Run one planned section on its specialist.

    Always returns a section dict. A specialist that fails marks its own
    section `ok: false` and the page is composed without it — one dead
    section must never cost the user the whole page.
    """
    result: dict[str, Any] = {
        "id": section["id"],
        "role": section["role"],
        "capability": section["capability"],
        "block": section["block"],
        "span": section["span"],
        "priority": section["priority"],
        "anchor": section["anchor"],
        "adjacency": section["adjacency"],
        "ok": True,
        "error": "",
    }
    prompt = section["prompt"]
    capability = section["capability"]
    box_width, box_height = _section_box(section["span"], page_width)
    result["box_width"] = box_width
    result["box_height"] = box_height

    try:
        if capability == "illustrator":
            # A drawing gets the box's proportions so a figure planned for a
            # square never arrives squashed into a wide half-column.
            drawing = illustrate(
                f"{prompt}\n\n[Compose for a region about {box_width} wide by "
                f"{box_height} tall — match that shape.]",
                quality=illustration_quality,
            )
            if drawing.get("kind") == "refusal":
                raise GeminiError(
                    str(drawing.get("message") or "Nothing drawable."))
            strokes = drawing.get("strokes") or []
            if not strokes:
                raise GeminiError("The drawing came back empty.")
            result["strokes"] = strokes
            result["label"] = str(drawing.get("label") or "illustration")[:120]
            # The compositor sizes a drawing by its aspect ratio: it knows the
            # column width and needs the height that keeps the figure true.
            result["aspect_ratio"] = drawing.get("aspect_ratio") or 1
        elif capability == "interactive":
            built = generate_interactive_block(
                f"{prompt}\n\n[Render box: about {box_width} x {box_height} "
                f"CSS pixels. Lay the whole thing out to fit that box without "
                f"inner scrolling, and set preferred_height to the height you "
                f"actually need, up to {box_height}.]",
                capability="interactive",
                language=language, math_detail=math_detail,
                max_height=box_height,
            )
            result["html"] = built["html"]
            result["title"] = built["title"]
            result["caption"] = built["reply"]
            result["preferred_height"] = built["preferred_height"]
            result["manifest"] = built["manifest"]
        elif capability == "language":
            turn = language_turn(prompt, language or "en-US")
            result["text"] = str(turn.get("reply") or "")
        elif capability == "debate":
            turn = debate_turn(prompt)
            # The counterpoint and its follow-up question are one panel on the
            # page, so they are joined rather than split across two sections.
            question = str(turn.get("question") or "").strip()
            result["text"] = "\n".join(
                part for part in
                (str(turn.get("counterargument") or "").strip(), question)
                if part
            )
        elif section["block"] in {"table", "checklist"}:
            result["text"] = generate_reply(
                prompt, capability="companion", math_detail=math_detail)
        else:
            result["text"] = generate_reply(
                prompt,
                capability=("mathematician" if capability == "mathematician"
                            else "companion"),
                math_detail=math_detail,
            )
    except Exception as exc:  # noqa: BLE001 — one section, not the page
        logger.warning(
            "Arranger section %s (%s) failed: %s",
            section["id"], capability, exc,
        )
        result["ok"] = False
        result["error"] = str(exc)[:200]
        result.setdefault("text", "")
    return result


def arrange_page(
    message: str,
    history: list[dict[str, Any]] | None = None,
    language: str = "",
    math_detail: str = "compact",
    illustration_quality: str = "detailed",
    page_width: float = 0,
) -> dict[str, Any]:
    """
    PEN-40 — plan a page, then build every section at once.

    Sections are independent by construction: the planner writes each prompt
    to stand alone, so there is no dependency chain to walk and the whole
    page can be built in one parallel wave. Wall-clock cost is therefore the
    SLOWEST section, not their sum — which is what makes a six-part page
    feel like one request instead of six.
    """
    from concurrent.futures import ThreadPoolExecutor

    plan = plan_page(message, history=history)
    sections = plan["sections"]

    workers = min(_ARRANGER_WORKERS, len(sections))
    if workers <= 1:
        rendered = [_render_section(
            sections[0], language, math_detail, illustration_quality,
            page_width)]
    else:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            rendered = list(pool.map(
                lambda section: _render_section(
                    section, language, math_detail, illustration_quality,
                    page_width),
                sections,
            ))

    rendered.sort(key=lambda section: section["priority"])
    usable = [section for section in rendered if section["ok"]]
    if not usable:
        raise GeminiError(
            "Every section of that page failed to build. Try a simpler request."
        )

    # A dropped section's anchor would dangle, so re-resolve against what
    # actually survived and close the gaps in the reading order.
    alive = {section["id"] for section in usable}
    for index, section in enumerate(usable, start=1):
        if section["anchor"] not in alive:
            section["anchor"], section["adjacency"] = "", ""
        section["priority"] = index

    return {
        "title": plan["title"],
        "template": plan["template"],
        "reply": plan["reply"],
        "sections": usable,
        "planned": len(sections),
        "failed": len(rendered) - len(usable),
    }
