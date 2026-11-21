"""
Framework-agnostic HTTP & SSE router for the Penpal brain.

Powers both:
- `src/worker.py` (Cloudflare Python Worker `WorkerEntrypoint.fetch`)
- Standalone local Python worker server (`python src/worker.py`)
"""

from __future__ import annotations

import base64
import binascii
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
import json
import logging
from typing import Any
from urllib.parse import urlsplit

from . import access, telemetry
from .config import bind_worker_env, runtime_settings as settings
from .gemini import (
    GeminiError,
    SUPPORTED_LANGUAGES,
    arrange_page,
    debate_turn as gemini_debate_turn,
    generate_interactive_block,
    generate_reply,
    grade_working,
    illustrate as gemini_illustrate,
    import_page as gemini_import_page,
    language_turn as gemini_language_turn,
    practice_problem,
    repair_interactive_block,
    solve_math_image,
    solve_worksheet,
    stream_math_reply,
    trace_image as gemini_trace_image,
    transcribe_math,
    vision_turn as gemini_vision_turn,
)

MAX_MESSAGE_CHARS = 4000
MAX_HISTORY_TURNS = 24
MAX_TURN_CHARS = 4000

logger = logging.getLogger(__name__)

CORS_HEADERS: dict[str, str] = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": (
        "Authorization, Content-Type, X-Penpal-Token, X-Penpal-Device-Id, X-Conversation-Id"
    ),
}


@dataclass
class RouteResponse:
    status: int
    payload: dict[str, Any] | str = field(default_factory=dict)
    headers: dict[str, str] = field(default_factory=dict)
    stream: Iterable[str] | None = None

    def __post_init__(self) -> None:
        self.headers = self.merged_headers()

    @property
    def is_stream(self) -> bool:
        return self.stream is not None

    def merged_headers(self) -> dict[str, str]:
        base = dict(CORS_HEADERS)
        if self.is_stream:
            base["Content-Type"] = "text/event-stream"
            base["Cache-Control"] = "no-cache"
            base["X-Accel-Buffering"] = "no"
        else:
            base["Content-Type"] = "application/json"
        base.update(self.headers)
        return base

    def body_text(self) -> str:
        if self.is_stream and self.stream is not None:
            text = "".join(self.stream)
            self.payload = text
            self.stream = None
            return text
        if isinstance(self.payload, str):
            return self.payload
        return json.dumps(self.payload)

    @property
    def body(self) -> bytes:
        return self.body_text().encode("utf-8")


def _json(data: dict[str, Any], status: int = 200,
          headers: dict[str, str] | None = None) -> RouteResponse:
    return RouteResponse(status=status, payload=data, headers=headers or {})


def _clean_history(raw: Any) -> list[dict[str, str]]:
    if not isinstance(raw, list):
        return []
    out: list[dict[str, str]] = []
    for turn in raw[-MAX_HISTORY_TURNS:]:
        if not isinstance(turn, dict):
            continue
        role = str(turn.get("role") or "").strip().lower()
        content = str(turn.get("content") or "").strip()[:MAX_TURN_CHARS]
        if not content:
            continue
        out.append({
            "role": "user" if role in ("user", "human") else "assistant",
            "content": content,
        })
    return out


def _decode_image(data: dict[str, Any]) -> tuple[bytes | None, RouteResponse | None]:
    raw = data.get("image") or ""
    if not isinstance(raw, str) or not raw.strip():
        return None, _json({"error": "image is required"}, status=400)
    if "," in raw[:64] and raw.strip().startswith("data:"):
        raw = raw.split(",", 1)[1]
    try:
        image_bytes = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError):
        return None, _json({"error": "image must be base64"}, status=400)
    if len(image_bytes) > 6 * 1024 * 1024:
        return None, _json({"error": "image too large"}, status=400)
    return image_bytes, None


def _handle_health() -> RouteResponse:
    return _json({
        "ok": True,
        "status": "ok",
        "service": "penpal-brain",
        "runtime": "cloudflare-python-worker",
        "verification": telemetry.snapshot(),
    })


def _handle_read_math(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    try:
        expression = transcribe_math(image_bytes)
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({"expression": expression, "model": settings.GEMINI_MODEL})


def _handle_solve_math(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    if not isinstance(data.get("history") or [], list):
        return _json({"error": "history must be a list"}, status=400)
    history = _clean_history(data.get("history"))
    math_detail = str(data.get("math_detail") or "compact").strip().lower()
    try:
        reply = solve_math_image(
            image_bytes,
            history=history,
            math_detail=math_detail,
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        "reply": reply,
        "model": settings.GEMINI_MODEL,
        "capability": "mathematician",
    })


def _handle_worksheet(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    math_detail = str(data.get("math_detail") or "compact").strip().lower()
    try:
        problems = solve_worksheet(image_bytes, math_detail=math_detail)
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        "problems": problems,
        "count": len(problems),
        "model": settings.GEMINI_MODEL,
    })


def _handle_import_page(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    try:
        blocks = gemini_import_page(image_bytes)
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        "blocks": blocks,
        "count": len(blocks),
        "model": settings.GEMINI_IMPORT_MODEL or settings.GEMINI_MODEL,
    })


def _handle_illustrate(data: dict[str, Any]) -> RouteResponse:
    message = str(data.get("message") or data.get("prompt") or "")
    message = message[:MAX_MESSAGE_CHARS].strip()
    if not message:
        return _json({"error": "message is required"}, status=400)
    default_quality = (
        "detailed"
        if getattr(settings, "ILLUSTRATOR_TRACE_ENABLED", True)
        else "quick"
    )
    quality = str(data.get("quality") or "").strip().lower()
    if quality not in ("quick", "balanced", "detailed"):
        quality = default_quality
    try:
        result = gemini_illustrate(message, quality=quality)
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        **result,
        "model": settings.GEMINI_ILLUSTRATOR_MODEL or settings.GEMINI_MODEL,
        "capability": "illustrator",
    })


def _handle_arrange(data: dict[str, Any]) -> RouteResponse:
    message = str(data.get("message") or data.get("text") or "")[:MAX_MESSAGE_CHARS]
    history = data.get("history") or []
    if not message.strip():
        return _json({"error": "message is required"}, status=400)
    if not isinstance(history, list):
        return _json({"error": "history must be a list"}, status=400)

    quality = str(data.get("illustration_quality") or "").strip().lower()
    if quality not in ("quick", "balanced", "detailed"):
        quality = (
            "detailed"
            if getattr(settings, "ILLUSTRATOR_TRACE_ENABLED", True)
            else "quick"
        )
    try:
        page_width = float(data.get("page_width") or 0)
    except (TypeError, ValueError):
        page_width = 0
    if not 200 <= page_width <= 4000:
        page_width = 0

    conversation_id = str(data.get("conversation_id") or "")[:100]
    try:
        result = arrange_page(
            message,
            history=_clean_history(history),
            language=str(data.get("language") or "")[:40],
            math_detail=str(data.get("math_detail") or "compact")[:20],
            illustration_quality=quality,
            page_width=page_width,
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    except Exception:  # noqa: BLE001
        logger.exception("Unexpected page arrangement failure")
        return _json(
            {"error": "The page could not be arranged. Try again."},
            status=503,
        )
    return _json({
        **result,
        "conversation_id": conversation_id,
        "model": settings.GEMINI_MODEL,
        "capability": "arranger",
    })


def _handle_trace_image(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    label = str(data.get("label") or "sketch").strip()[:120] or "sketch"
    mode = str(data.get("mode") or "auto").strip().lower()
    if mode not in ("auto", "lineart", "photo"):
        mode = "auto"
    quality = str(data.get("quality") or "").strip().lower()
    if quality not in ("quick", "balanced", "detailed"):
        quality = "detailed"
    try:
        result = gemini_trace_image(
            image_bytes,
            label=label,
            mode=mode,
            quality=quality,
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({**result, "capability": "illustrator"})


def _handle_language_turn(data: dict[str, Any]) -> RouteResponse:
    message = str(data.get("message") or "")[:MAX_MESSAGE_CHARS].strip()
    if not message:
        return _json({"error": "message is required"}, status=400)
    language_code = str(data.get("language") or "").strip()
    if language_code not in SUPPORTED_LANGUAGES:
        return _json({"error": "unsupported language"}, status=400)
    if not isinstance(data.get("history") or [], list):
        return _json({"error": "history must be a list"}, status=400)
    history = _clean_history(data.get("history"))
    try:
        result = gemini_language_turn(message, language_code, history=history)
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        **result,
        "model": settings.GEMINI_LANGUAGE_MODEL or settings.GEMINI_MODEL,
        "capability": "language",
    })


def _handle_debate_turn(data: dict[str, Any]) -> RouteResponse:
    message = str(data.get("message") or "")[:MAX_MESSAGE_CHARS].strip()
    if not message:
        return _json({"error": "message is required"}, status=400)
    if not isinstance(data.get("history") or [], list):
        return _json({"error": "history must be a list"}, status=400)
    try:
        result = gemini_debate_turn(
            message,
            history=_clean_history(data.get("history")),
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        **result,
        "model": settings.GEMINI_DEBATE_MODEL or settings.GEMINI_MODEL,
        "capability": "debate",
        "trust": "perspective",
    })


def _handle_vision_turn(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    capability = str(data.get("capability") or "companion").strip().lower()
    if capability not in (
        "companion",
        "mathematician",
        "language",
        "debate",
        "interactive",
        "arranger",
    ):
        return _json({"error": "unsupported vision capability"}, status=400)
    if not isinstance(data.get("history") or [], list):
        return _json({"error": "history must be a list"}, status=400)
    mime_type = str(data.get("mime_type") or "image/jpeg").strip().lower()
    if mime_type not in ("image/jpeg", "image/png"):
        return _json({"error": "unsupported image type"}, status=400)
    try:
        result = gemini_vision_turn(
            image_bytes=image_bytes,
            mime_type=mime_type,
            capability=capability,
            message=str(data.get("message") or ""),
            history=_clean_history(data.get("history")),
            math_detail=str(data.get("math_detail") or "compact"),
            language_code=str(data.get("language") or "es-ES"),
            mood=str(data.get("mood") or "warm").strip().lower(),
            custom_mood=str(data.get("custom_mood") or "").strip()[:500],
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        **result,
        "capability": capability,
        "model": (
            settings.GEMINI_MODEL if result.get("kind") == "math"
            else settings.GEMINI_VISION_MODEL or settings.GEMINI_MODEL
        ),
    })


def _handle_check_work(data: dict[str, Any]) -> RouteResponse:
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    try:
        result = grade_working(image_bytes)
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({**result, "model": settings.GEMINI_MODEL})


def _handle_solve_stream(data: dict[str, Any]) -> RouteResponse:
    message = str(data.get("message") or "")[:MAX_MESSAGE_CHARS]
    if not message.strip():
        return _json({"error": "message is required"}, status=400)
    history = _clean_history(data.get("history"))
    math_detail = str(data.get("math_detail") or "compact").strip().lower()

    def events():
        try:
            for event in stream_math_reply(
                message, history=history, math_detail=math_detail
            ):
                yield f"data: {json.dumps(event)}\n\n"
        except GeminiError as exc:
            yield f'data: {json.dumps({"type": "error", "message": str(exc)})}\n\n'

    return RouteResponse(status=200, stream=events())


def _handle_practice(data: dict[str, Any]) -> RouteResponse:
    topic = str(data.get("topic") or "").strip()
    if not topic:
        return _json({"error": "topic is required"}, status=400)
    try:
        result = practice_problem(
            topic=topic,
            mistake=str(data.get("mistake") or ""),
            difficulty=str(data.get("difficulty") or "same"),
            domain=str(data.get("domain") or "math"),
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({**result, "model": settings.GEMINI_MODEL})


def _handle_interactive(data: dict[str, Any]) -> RouteResponse:
    message = str(data.get("message") or data.get("text") or "")[:MAX_MESSAGE_CHARS]
    history = data.get("history") or []
    if not message.strip():
        return _json({"error": "message is required"}, status=400)
    if not isinstance(history, list):
        return _json({"error": "history must be a list"}, status=400)

    capability = str(data.get("capability") or "interactive").strip().lower()
    conversation_id = str(data.get("conversation_id") or "")[:100]
    try:
        result = generate_interactive_block(
            message,
            history=_clean_history(history),
            capability=capability,
            language=str(data.get("language") or "")[:40],
            math_detail=str(data.get("math_detail") or "compact")[:20],
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    except Exception:  # noqa: BLE001
        logger.exception("Unexpected interactive build failure")
        return _json(
            {"error": "The interactive build failed unexpectedly. Try again."},
            status=503,
        )
    return _json({
        **result,
        "conversation_id": conversation_id,
        "model": settings.GEMINI_MODEL,
        "capability": capability,
    })


def _handle_repair_interactive(data: dict[str, Any]) -> RouteResponse:
    html = str(data.get("html") or "")
    manifest = data.get("manifest")
    diagnostics = data.get("diagnostics")
    if not html.strip():
        return _json({"error": "html is required"}, status=400)
    if manifest is not None and not isinstance(manifest, dict):
        return _json({"error": "manifest must be an object"}, status=400)
    if not isinstance(diagnostics, list) or not diagnostics:
        return _json({"error": "diagnostics must be a non-empty list"}, status=400)
    try:
        result = repair_interactive_block(
            html=html,
            manifest=manifest,
            diagnostics=diagnostics,
            title=str(data.get("title") or "Interactive Block")[:80],
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    except Exception:  # noqa: BLE001
        logger.exception("Unexpected interactive repair failure")
        return _json(
            {"error": "The repair failed unexpectedly. Try again."},
            status=503,
        )
    return _json({
        **result,
        "model": settings.GEMINI_MODEL,
        "capability": "interactive",
    })


def _handle_chat(data: dict[str, Any]) -> RouteResponse:
    message = data.get("message") or data.get("text") or ""
    history = data.get("history") or []
    conversation_id = data.get("conversation_id") or ""
    capability = str(data.get("capability") or "companion").strip().lower()
    mood = str(data.get("mood") or "warm").strip().lower()
    custom_mood = str(data.get("custom_mood") or "").strip()[:500]
    math_detail = str(data.get("math_detail") or "compact").strip().lower()
    if capability not in ("companion", "mathematician"):
        capability = "companion"
    if not isinstance(history, list):
        return _json({"error": "history must be a list"}, status=400)
    history = _clean_history(history)
    message = str(message)[:MAX_MESSAGE_CHARS]
    if not message.strip():
        return _json({"error": "message is required"}, status=400)
    try:
        reply = generate_reply(
            message,
            history=history,
            capability=capability,
            mood=mood,
            custom_mood=custom_mood,
            math_detail=math_detail,
        )
    except GeminiError as exc:
        return _json({"error": str(exc)}, status=503)
    return _json({
        "reply": reply,
        "conversation_id": conversation_id,
        "model": settings.GEMINI_MODEL,
        "capability": capability,
    })


_POST_HANDLERS = {
    "/api/chat": _handle_chat,
    "/api/interactive": _handle_interactive,
    "/api/interactive/repair": _handle_repair_interactive,
    "/api/arrange": _handle_arrange,
    "/api/read-math": _handle_read_math,
    "/api/solve-math": _handle_solve_math,
    "/api/solve-image": _handle_solve_math,
    "/api/worksheet": _handle_worksheet,
    "/api/solve-worksheet": _handle_worksheet,
    "/api/import-page": _handle_import_page,
    "/api/illustrate": _handle_illustrate,
    "/api/trace-image": _handle_trace_image,
    "/api/trace": _handle_trace_image,
    "/api/language-turn": _handle_language_turn,
    "/api/debate-turn": _handle_debate_turn,
    "/api/vision-turn": _handle_vision_turn,
    "/api/check-work": _handle_check_work,
    "/api/practice": _handle_practice,
    "/api/solve-stream": _handle_solve_stream,
    "/api/solve-math/stream": _handle_solve_stream,
    "/api/solve-image/stream": _handle_solve_stream,
}


def dispatch(
    method: str,
    url_or_path: str,
    headers: Mapping[str, Any] | None = None,
    body: bytes | str | dict[str, Any] | None = None,
    env: Any = None,
) -> RouteResponse:
    """
    Dispatch an HTTP request to the matching Penpal `/api/*` handler.
    Binds `env` (if provided by Cloudflare Workers) for the duration of the call.
    """
    method_upper = (method or "GET").strip().upper()
    parsed_path = urlsplit(url_or_path or "/").path.rstrip("/") or "/"
    req_headers = headers or {}

    if method_upper == "OPTIONS":
        return RouteResponse(status=204, payload="", headers={})

    with bind_worker_env(env):
        if parsed_path in ("/api/health", "/health"):
            if method_upper != "GET":
                return _json({"error": "Method not allowed"}, status=405)
            return _handle_health()

        handler = _POST_HANDLERS.get(parsed_path)
        if handler is None:
            return _json({"error": "Not found"}, status=404)
        if method_upper != "POST":
            return _json({"error": "Method not allowed"}, status=405)

        denied = access.check_headers(req_headers)
        if denied is not None:
            status_code, extra_headers, err_payload = denied
            return _json(err_payload, status=status_code, headers=extra_headers)

        if isinstance(body, dict):
            data = body
        elif body is None or body == "" or body == b"":
            data = {}
        else:
            raw_text = (
                body.decode("utf-8", errors="replace")
                if isinstance(body, (bytes, bytearray))
                else str(body)
            )
            try:
                parsed = json.loads(raw_text) if raw_text.strip() else {}
                data = parsed if isinstance(parsed, dict) else {}
            except json.JSONDecodeError:
                return _json({"error": "Invalid JSON body"}, status=400)

        try:
            response = handler(data)
            if response.is_stream and response.stream is not None:
                # Materialize inside the bound env context so streaming yields see
                # the Worker's secrets and model settings.
                chunks = list(response.stream)
                return RouteResponse(
                    status=response.status,
                    headers=response.headers,
                    stream=iter(chunks),
                )
            return response
        except GeminiError as exc:
            return _json({"error": str(exc)}, status=503)
        except Exception as exc:  # noqa: BLE001
            logger.exception("Unhandled error in Worker router")
            return _json(
                {"error": f"{type(exc).__name__}: {exc}"},
                status=503,
            )
