from rest_framework import status
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.conf import settings

import base64
import binascii
import logging

from . import access, telemetry
import json

from django.http import StreamingHttpResponse

from .gemini import (
    GeminiError,
    SUPPORTED_LANGUAGES,
    arrange_page,
    debate_turn as gemini_debate_turn,
    generate_interactive_block,
    generate_reply,
    grade_working,
    illustrate as gemini_illustrate,
    trace_image as gemini_trace_image,
    import_page as gemini_import_page,
    language_turn as gemini_language_turn,
    practice_problem,
    repair_interactive_block,
    stream_math_reply,
    solve_math_image,
    solve_worksheet,
    transcribe_math,
    vision_turn as gemini_vision_turn,
)


# Server-side input limits. The client caps these too, but the server must
# never trust the client: an oversized message or a 500-turn history is a
# direct token-cost blowup and a trivial denial-of-wallet vector.
MAX_MESSAGE_CHARS = 4000
MAX_HISTORY_TURNS = 24

logger = logging.getLogger(__name__)
MAX_TURN_CHARS = 4000


def _clean_history(raw) -> list:
    """Validated, bounded conversation history."""
    if not isinstance(raw, list):
        return []
    out = []
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


def _decode_image(data: dict):
    """Shared base64-image extraction. Returns (bytes, error_response)."""
    raw = data.get("image") or ""
    if not isinstance(raw, str) or not raw.strip():
        return None, Response({"error": "image is required"},
                              status=status.HTTP_400_BAD_REQUEST)
    # Tolerate data-URL prefixes.
    if "," in raw[:64] and raw.strip().startswith("data:"):
        raw = raw.split(",", 1)[1]
    try:
        image_bytes = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError):
        return None, Response({"error": "image must be base64"},
                              status=status.HTTP_400_BAD_REQUEST)
    if len(image_bytes) > 6 * 1024 * 1024:
        return None, Response({"error": "image too large"},
                              status=status.HTTP_400_BAD_REQUEST)
    return image_bytes, None


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def health(request):
    """
    Liveness plus verification health (PEN-04).

    `verification.status` is the number that matters: "healthy" means answers
    are actually being checked. "unverified" means the referee is failing and
    we are shipping unchecked answers that still *look* verified — the exact
    silent failure BB-03 hid for an unknown period.
    """
    return Response({
        "ok": True,
        "service": "penpal-brain",
        "verification": telemetry.snapshot(),
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def read_math(request):
    """
    Transcribe handwritten maths from an image.

    Body: {"image": "<base64 png>"}
    Returns: {"expression": "1/2 + 1/3 + 1/6 ="}
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err

    try:
        expression = transcribe_math(image_bytes)
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({"expression": expression, "model": settings.GEMINI_MODEL})


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def solve_math(request):
    """
    Solve a boxed handwritten problem straight from its image — no OCR.

    Body: {"image": "<base64 png>",
           "history": [{"role": ..., "content": ...}, ...]   (optional)
           "math_detail": "answer"|"compact"|"full"|"proof"  (optional)}
    Returns: {"reply": "<worked solution>"}
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err

    if not isinstance(data.get("history") or [], list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)
    history = _clean_history(data.get("history"))
    math_detail = str(data.get("math_detail") or "compact").strip().lower()

    try:
        reply = solve_math_image(
            image_bytes,
            history=history,
            math_detail=math_detail,
        )
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        "reply": reply,
        "model": settings.GEMINI_MODEL,
        "capability": "mathematician",
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def worksheet(request):
    """
    PEN-15 — solve every problem on a worksheet in one pass.

    Body: {"image": "<base64 png>",
           "math_detail": "answer"|"compact"|"full"|"proof"  (optional)}
    Returns: {"problems": [{label, reading, steps, answer, readable}, ...]}

    Structured rather than prose because the app places each answer beside its
    own problem on the page.
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err

    math_detail = str(data.get("math_detail") or "compact").strip().lower()

    try:
        problems = solve_worksheet(image_bytes, math_detail=math_detail)
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        "problems": problems,
        "count": len(problems),
        "model": settings.GEMINI_MODEL,
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def import_page(request):
    """
    PEN-35 — photo import. Read an existing paper page and return it as an
    ordered list of blocks the app rebuilds on a live page: "text"/"math"
    blocks are written as real ink, "image" blocks (diagrams, tables, photos
    — anything that can't honestly become handwriting) keep a crop box so
    the app drops in the real pixels instead of a fake reconstruction.

    Body: {"image": "<base64 png/jpeg>"}
    Returns: {"blocks": [...], "count": N}
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err

    try:
        blocks = gemini_import_page(image_bytes)
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        "blocks": blocks,
        "count": len(blocks),
        "model": settings.GEMINI_IMPORT_MODEL or settings.GEMINI_MODEL,
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def illustrate(request):
    """
    PEN-36 — turn a drawing request into ordered pen strokes.

    Educational and labelled diagrams are allowed. Only unsafe requests return
    a structured refusal.
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = str(data.get("message") or data.get("prompt") or "")
    message = message[:MAX_MESSAGE_CHARS].strip()
    if not message:
        return Response({"error": "message is required"},
                        status=status.HTTP_400_BAD_REQUEST)

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
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        **result,
        "model": settings.GEMINI_ILLUSTRATOR_MODEL or settings.GEMINI_MODEL,
        "capability": "illustrator",
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def arrange(request):
    """
    PEN-40 — plan a whole page and build every section in parallel.

    Returns the composition plan plus each section's content. Deliberately
    returns no geometry: only the device knows the page width, the user's
    handwriting size, and how tall the rendered ink will actually be, so it
    solves the layout itself from the roles, spans and anchors here.
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = str(data.get("message") or data.get("text") or "")[:MAX_MESSAGE_CHARS]
    history = data.get("history") or []
    if not message.strip():
        return Response({"error": "message is required"},
                        status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(history, list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)

    quality = str(data.get("illustration_quality") or "").strip().lower()
    if quality not in ("quick", "balanced", "detailed"):
        quality = ("detailed"
                   if getattr(settings, "ILLUSTRATOR_TRACE_ENABLED", True)
                   else "quick")

    # The device reports its writable width so each specialist can be told
    # the size of the box it is building for. Without it a block is designed
    # for an imaginary viewport and lands needing a manual resize.
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
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)
    except Exception:  # noqa: BLE001 — a bug here must not leak a traceback
        logger.exception("Unexpected page arrangement failure")
        return Response(
            {"error": "The page could not be arranged. Try again."},
            status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        **result,
        "conversation_id": conversation_id,
        "model": settings.GEMINI_MODEL,
        "capability": "arranger",
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def trace_image(request):
    """
    PEN-36 (Goal B) — trace a user-provided image into ordered pen strokes.

    Body: {"image": "<base64 png/jpeg>", "label": "<optional>",
           "mode": "auto|lineart|photo",
           "quality": "quick|balanced|detailed"}. Pure computer vision on the
    server — no model call — so the user's own photo is never sent to Gemini.
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
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
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({**result, "capability": "illustrator"})


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def language_turn(request):
    """PEN-37 — target-language reply plus at most one gentle correction."""
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = str(data.get("message") or "")[:MAX_MESSAGE_CHARS].strip()
    if not message:
        return Response({"error": "message is required"},
                        status=status.HTTP_400_BAD_REQUEST)
    language_code = str(data.get("language") or "").strip()
    if language_code not in SUPPORTED_LANGUAGES:
        return Response({"error": "unsupported language"},
                        status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(data.get("history") or [], list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)
    history = _clean_history(data.get("history"))

    try:
        result = gemini_language_turn(message, language_code, history=history)
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        **result,
        "model": settings.GEMINI_LANGUAGE_MODEL or settings.GEMINI_MODEL,
        "capability": "language",
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def debate_turn(request):
    """PEN-38 — strongest good-faith counterargument, never a verdict."""
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = str(data.get("message") or "")[:MAX_MESSAGE_CHARS].strip()
    if not message:
        return Response({"error": "message is required"},
                        status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(data.get("history") or [], list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)

    try:
        result = gemini_debate_turn(
            message,
            history=_clean_history(data.get("history")),
        )
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        **result,
        "model": settings.GEMINI_DEBATE_MODEL or settings.GEMINI_MODEL,
        "capability": "debate",
        # Explicit trust tier: useful perspective, not independently verified.
        "trust": "perspective",
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def vision_turn(request):
    """PEN-39 — ask the selected capability about an external photo."""
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err
    capability = str(data.get("capability") or "companion").strip().lower()
    if capability not in ("companion", "mathematician", "language", "debate"):
        return Response({"error": "unsupported vision capability"},
                        status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(data.get("history") or [], list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)
    mime_type = str(data.get("mime_type") or "image/jpeg").strip().lower()
    if mime_type not in ("image/jpeg", "image/png"):
        return Response({"error": "unsupported image type"},
                        status=status.HTTP_400_BAD_REQUEST)

    try:
        result = gemini_vision_turn(
            image_bytes=image_bytes,
            mime_type=mime_type,
            capability=capability,
            message=str(data.get("message") or ""),
            history=_clean_history(data.get("history")),
            math_detail=str(data.get("math_detail") or "compact"),
            language_code=str(data.get("language") or "es-ES"),
        )
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        **result,
        "capability": capability,
        "model": (
            settings.GEMINI_MODEL if result.get("kind") == "math"
            else settings.GEMINI_VISION_MODEL or settings.GEMINI_MODEL
        ),
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def check_work(request):
    """
    PEN-16 — mark the student's own working, first wrong line only.

    Body: {"image": "<base64 png>"}
    Returns: {problem, verdict, line_number, line_text, box, reason,
              correction, final_answer}
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err

    try:
        result = grade_working(image_bytes)
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({**result, "model": settings.GEMINI_MODEL})


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def solve_stream(request):
    """
    PEN-28 — server-sent events for a streamed solution.

    Emits `data: {json}\\n\\n` lines of {"type": ..., "text": ...}. The client
    treats "draft" as provisional (rendered as a ghost) and only commits ink
    on "final" or "corrected" — see `stream_math_reply` for why.
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = str(data.get("message") or "")[:MAX_MESSAGE_CHARS]
    if not message.strip():
        return Response({"error": "message is required"},
                        status=status.HTTP_400_BAD_REQUEST)
    history = _clean_history(data.get("history"))
    math_detail = str(data.get("math_detail") or "compact").strip().lower()

    def events():
        try:
            for event in stream_math_reply(message, history=history,
                                           math_detail=math_detail):
                yield f"data: {json.dumps(event)}\n\n"
        except GeminiError as exc:
            yield f'data: {json.dumps({"type": "error", "message": str(exc)})}\n\n'

    response = StreamingHttpResponse(events(),
                                     content_type="text/event-stream")
    # Proxies buffering an event stream would defeat the entire point.
    response["Cache-Control"] = "no-cache"
    response["X-Accel-Buffering"] = "no"
    return response


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def practice(request):
    """
    PEN-19 — a practice problem aimed at a past mistake.

    Body: {"topic": "...", "mistake": "..." (optional),
           "difficulty": "easier"|"same"|"harder" (optional)}
    Returns: {problem, answer, hint, skill}
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    topic = str(data.get("topic") or "").strip()
    if not topic:
        return Response({"error": "topic is required"},
                        status=status.HTTP_400_BAD_REQUEST)

    try:
        result = practice_problem(
            topic=topic,
            mistake=str(data.get("mistake") or ""),
            difficulty=str(data.get("difficulty") or "same"),
            domain=str(data.get("domain") or "math"),
        )
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({**result, "model": settings.GEMINI_MODEL})


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def interactive(request):
    """Generate one isolated browser block and its consent manifest."""
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = str(data.get("message") or data.get("text") or "")[:MAX_MESSAGE_CHARS]
    history = data.get("history") or []
    if not message.strip():
        return Response({"error": "message is required"},
                        status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(history, list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)

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
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)
    except Exception:  # noqa: BLE001 — a bug here must not leak a traceback
        logger.exception("Unexpected interactive build failure")
        return Response(
            {"error": "The interactive build failed unexpectedly. Try again."},
            status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({
        **result,
        "conversation_id": conversation_id,
        "model": settings.GEMINI_MODEL,
        "capability": capability,
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def repair_interactive(request):
    """Investigate privacy-bounded diagnostics and return a full replacement."""
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    html = str(data.get("html") or "")
    manifest = data.get("manifest")
    diagnostics = data.get("diagnostics")
    if not html.strip():
        return Response({"error": "html is required"},
                        status=status.HTTP_400_BAD_REQUEST)
    if manifest is not None and not isinstance(manifest, dict):
        return Response({"error": "manifest must be an object"},
                        status=status.HTTP_400_BAD_REQUEST)
    if not isinstance(diagnostics, list) or not diagnostics:
        return Response({"error": "diagnostics must be a non-empty list"},
                        status=status.HTTP_400_BAD_REQUEST)

    try:
        result = repair_interactive_block(
            html=html,
            manifest=manifest,
            diagnostics=diagnostics,
            title=str(data.get("title") or "Interactive Block")[:80],
        )
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)
    except Exception:  # noqa: BLE001 — a bug here must not leak a traceback
        logger.exception("Unexpected interactive repair failure")
        return Response(
            {"error": "The repair failed unexpectedly. Try again."},
            status=status.HTTP_503_SERVICE_UNAVAILABLE)
    return Response({
        **result,
        "model": settings.GEMINI_MODEL,
        "capability": "interactive",
    })


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def chat(request):
    """
    Body:
      {
        "message": "what the user wrote",
        "conversation_id": "optional-uuid",
        "history": [{"role": "user"|"assistant", "content": "..."}, ...]
      }
    """
    denied = access.check(request)
    if denied is not None:
        return denied

    data = request.data if isinstance(request.data, dict) else {}
    message = data.get("message") or data.get("text") or ""
    history = data.get("history") or []
    conversation_id = data.get("conversation_id") or ""
    # Capability routing: "companion" (default) or "mathematician".
    capability = str(data.get("capability") or "companion").strip().lower()
    mood = str(data.get("mood") or "warm").strip().lower()
    custom_mood = str(data.get("custom_mood") or "").strip()[:500]
    math_detail = str(data.get("math_detail") or "compact").strip().lower()
    if capability not in ("companion", "mathematician"):
        capability = "companion"

    if not isinstance(history, list):
        return Response(
            {"error": "history must be a list"},
            status=status.HTTP_400_BAD_REQUEST,
        )
    history = _clean_history(history)
    message = str(message)[:MAX_MESSAGE_CHARS]
    if not str(message).strip():
        return Response(
            {"error": "message is required"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    try:
        reply = generate_reply(
            str(message),
            history=history,
            capability=capability,
            mood=mood,
            custom_mood=custom_mood,
            math_detail=math_detail,
        )
    except GeminiError as exc:
        return Response(
            {"error": str(exc)},
            status=status.HTTP_503_SERVICE_UNAVAILABLE,
        )

    return Response(
        {
            "reply": reply,
            "conversation_id": conversation_id,
            "model": settings.GEMINI_MODEL,
            "capability": capability,
        }
    )
