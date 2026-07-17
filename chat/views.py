from rest_framework import status
from rest_framework.decorators import api_view, authentication_classes, permission_classes
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from django.conf import settings

from .gemini import GeminiError, generate_reply


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def health(request):
    return Response({"ok": True, "service": "penpal-brain"})


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
        reply = generate_reply(str(message), history=history)
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
        }
    )
