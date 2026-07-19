from rest_framework import status
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.conf import settings

import base64
import binascii

from . import access, telemetry
import json

from django.http import StreamingHttpResponse

from .gemini import (
    GeminiError,
    generate_reply,
    grade_working,
    practice_problem,
    stream_math_reply,
    solve_math_image,
    solve_worksheet,
    transcribe_math,
)


# Server-side input limits. The client caps these too, but the server must
# never trust the client: an oversized message or a 500-turn history is a
# direct token-cost blowup and a trivial denial-of-wallet vector.
MAX_MESSAGE_CHARS = 4000
MAX_HISTORY_TURNS = 24
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
        )
    except GeminiError as exc:
        return Response({"error": str(exc)},
                        status=status.HTTP_503_SERVICE_UNAVAILABLE)

    return Response({**result, "model": settings.GEMINI_MODEL})


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
