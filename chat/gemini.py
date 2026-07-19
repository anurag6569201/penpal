"""Gemini client for Penpal replies."""

from __future__ import annotations

import logging
from typing import Any

from django.conf import settings
from google import genai
from google.genai import types

from . import mathengine, routing, telemetry
from .prompts import (
    GRADER_SYSTEM_PROMPT,
    MATH_CORRECTOR_NOTE,
    MATH_DETAIL,
    PRACTICE_SYSTEM_PROMPT,
    MATH_VERIFIER_PROMPT,
    MATH_VISION_PROMPT,
    WORKSHEET_CORRECTOR_NOTE,
    WORKSHEET_SYSTEM_PROMPT,
    WORKSHEET_VERIFIER_PROMPT,
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
                system_instruction=PRACTICE_SYSTEM_PROMPT,
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
