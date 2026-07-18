from rest_framework import status
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.conf import settings

import base64
import binascii

from .gemini import GeminiError, generate_reply, solve_math_image, transcribe_math


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
    return Response({"ok": True, "service": "penpal-brain"})


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def read_math(request):
    """
    Transcribe handwritten maths from an image.

    Body: {"image": "<base64 png>"}
    Returns: {"expression": "1/2 + 1/3 + 1/6 ="}
    """
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
    data = request.data if isinstance(request.data, dict) else {}
    image_bytes, err = _decode_image(data)
    if err is not None:
        return err

    history = data.get("history") or []
    if not isinstance(history, list):
        return Response({"error": "history must be a list"},
                        status=status.HTTP_400_BAD_REQUEST)
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
def chat(request):
    """
    Body:
      {
        "message": "what the user wrote",
        "conversation_id": "optional-uuid",
        "history": [{"role": "user"|"assistant", "content": "..."}, ...]
      }
    """
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
