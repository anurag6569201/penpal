"""Gemini client for Penpal replies."""

from __future__ import annotations

import logging
import math
import re
import unicodedata
from typing import Any

from django.conf import settings
from google import genai
from google.genai import types

from . import mathengine, routing, telemetry, tracer
from .prompts import (
    GRADER_SYSTEM_PROMPT,
    DEBATE_SYSTEM_PROMPT,
    IMPORT_SYSTEM_PROMPT,
    ILLUSTRATOR_SYSTEM_PROMPT,
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


def _parse_json_block(text: str) -> Any:
    """
    Tolerant JSON extraction. Models wrap output in fences, prepend "Sure!",
    or get truncated when thinking shares the token budget — none of which
    should cost the user their whole worksheet.
    """
    import json
    import re

    text = (text or "").strip()
    if text.startswith("```"):
        lines = text.splitlines()
        text = "\n".join(lines[1:-1] if len(lines) > 2 else lines).strip()
        if text.startswith("json"):
            text = text[4:].strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    match = re.search(r"[{\[].*[}\]]", text, re.S)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass
    raise ValueError("no JSON object found")


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
                max_output_tokens=8000,
                response_mime_type="application/json",
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
                max_output_tokens=8000,
                response_mime_type="application/json",
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
            "message": message or (
                "I need a trusted reference to draw that accurately, "
                "so I won't guess."
            ),
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
    the trace path fails. Factual/labelled diagrams fail closed as a refusal
    because this path has no vetted reference to trace.
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
                system_instruction=ILLUSTRATOR_SYSTEM_PROMPT,
                temperature=0.35,
                top_p=0.9,
                max_output_tokens=8000,
                response_mime_type="application/json",
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Illustration planning failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    try:
        return _clean_illustration(
            _parse_json_block(_extract_text(response)), quality=quality
        )
    except ValueError as exc:
        raise GeminiError(f"Could not draw that: {exc}") from exc


def _gate_illustration(message: str, quality: str) -> dict[str, Any]:
    """
    Decide refuse-vs-draw for the trace path, and — if allowed — write the image
    prompt. Keeping the correctness boundary on the text model means an unsafe or
    factual request is refused *before* any image quota is spent.
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
                max_output_tokens=800,
                response_mime_type="application/json",
            ),
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Illustration gate failed")
        raise GeminiError(str(exc)) from exc

    _account(model, response)
    raw = _parse_json_block(_extract_text(response))
    if not isinstance(raw, dict):
        raise GeminiError("Illustration gate returned no decision.")
    kind = str(raw.get("kind") or "").strip().lower()
    if kind == "refusal":
        message_out = str(raw.get("message") or "").strip()[:240]
        return {"kind": "refusal", "message": message_out or (
            "I need a trusted reference to draw that accurately, so I won't guess."
        )}
    prompt = str(raw.get("image_prompt") or "").strip()
    if kind != "image" or not prompt:
        raise GeminiError("Illustration gate produced no image prompt.")
    aspect_ratio = str(raw.get("aspect_ratio") or "1:1").strip()
    if aspect_ratio not in ("1:1", "4:3", "3:4", "16:9", "9:16"):
        aspect_ratio = "1:1"
    return {
        "kind": "image",
        "label": str(raw.get("label") or "illustration").strip()[:120] or "illustration",
        "image_prompt": prompt[:1500],
        "aspect_ratio": aspect_ratio,
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
    PEN-36 — turn an imaginative request into ordered pen strokes.

    Quick has the model author stroke geometry directly. Balanced and Detailed
    render the subject with an image model and trace it into ink. Trace degrades
    to a Quick plan on any pipeline failure, so the page still gets a drawing;
    a *refusal* from the gate is returned as-is and never redrawn as a guess.

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
        return {
            **_illustrate_plan(message, quality="quick"),
            "quality": "quick",
            "pipeline": "plan_fallback",
        }


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
