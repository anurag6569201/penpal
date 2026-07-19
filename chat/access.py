"""
PEN-26 — access control and rate limiting.

Threat model, stated plainly: this server holds a Gemini API key and will
spend it on request. Every endpoint was `AllowAny` with no throttle, so
anyone who could reach the host — anyone on the coffee-shop wifi, anyone
who found the box on the open internet — could burn the owner's quota.
That is the practical risk here; not data theft, but a bill.

Design choices:

* **Shared tokens, not user accounts.** Penpal has no notion of users and
  doesn't want one. A per-device token in the app's settings is the smallest
  thing that solves the actual problem. Adding accounts would be a bigger
  product decision that this security fix should not smuggle in.
* **In-process counters, not Redis.** One small server, one process. A
  dependency-free limiter that is always on beats a better one that isn't
  deployed. Documented as the upgrade point if this ever scales out.
* **Constant-time comparison.** Token checks use `secrets.compare_digest` so
  a timing side channel can't leak the token character by character.
* **Dev mode stays frictionless.** With `PENPAL_DEV=1` and no tokens set,
  everything is open, exactly as before. Settings refuses to boot in any
  other configuration without tokens, so the insecure path cannot be reached
  by accident.
"""

from __future__ import annotations

import secrets
import threading
import time
from collections import defaultdict, deque

from django.conf import settings
from rest_framework import status
from rest_framework.response import Response

_lock = threading.Lock()
# token -> deque[timestamp]; bounded by pruning, never grows unbounded.
_minute_hits: dict[str, deque] = defaultdict(deque)
_day_hits: dict[str, deque] = defaultdict(deque)

MINUTE = 60
DAY = 86_400


def _client_token(request) -> str | None:
    """
    Token from `Authorization: Bearer <token>` or `X-Penpal-Token`.
    Returns None when absent.
    """
    header = request.META.get("HTTP_AUTHORIZATION", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip() or None
    return request.META.get("HTTP_X_PENPAL_TOKEN", "").strip() or None


def _token_is_valid(candidate: str) -> bool:
    # Constant-time against every configured token.
    return any(secrets.compare_digest(candidate, known)
               for known in settings.PENPAL_TOKENS)


def _prune(hits: deque, window: int, now: float) -> None:
    while hits and now - hits[0] > window:
        hits.popleft()


def check(request) -> Response | None:
    """
    Returns an error Response when the request must be refused, else None.

    Callers use it as a guard:
        denied = access.check(request)
        if denied is not None:
            return denied
    """
    configured = settings.PENPAL_TOKENS

    # Dev mode with no tokens configured: wide open, as before.
    if not configured:
        return None

    token = _client_token(request)
    if not token or not _token_is_valid(token):
        return Response(
            {"error": "Invalid or missing access token."},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    now = time.time()
    with _lock:
        minute, day = _minute_hits[token], _day_hits[token]
        _prune(minute, MINUTE, now)
        _prune(day, DAY, now)

        if len(minute) >= settings.RATE_LIMIT_PER_MINUTE:
            retry = int(MINUTE - (now - minute[0])) + 1
            return _limited("Too many requests — give it a moment.", retry)

        if len(day) >= settings.RATE_LIMIT_PER_DAY:
            retry = int(DAY - (now - day[0])) + 1
            return _limited("Daily limit reached.", retry)

        minute.append(now)
        day.append(now)
    return None


def _limited(message: str, retry_after: int) -> Response:
    response = Response({"error": message},
                        status=status.HTTP_429_TOO_MANY_REQUESTS)
    response["Retry-After"] = str(max(1, retry_after))
    return response


def reset() -> None:
    """Test hook."""
    with _lock:
        _minute_hits.clear()
        _day_hits.clear()
