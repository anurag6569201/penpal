"""
PEN-26 — access control and rate limiting.

Works in both Cloudflare Python Workers (via `check_headers`) and Django
(via `check(request)`).
"""

from __future__ import annotations

from collections import defaultdict, deque
from collections.abc import Mapping
import secrets
import threading
import time
from typing import Any

from .config import runtime_settings as settings

_lock = threading.Lock()
# token -> deque[timestamp]; bounded by pruning, never grows unbounded.
_minute_hits: dict[str, deque] = defaultdict(deque)
_day_hits: dict[str, deque] = defaultdict(deque)

MINUTE = 60
DAY = 86_400


def _token_from_headers(headers: Mapping[str, Any]) -> str | None:
    """
    Extract token from `Authorization: Bearer <token>` or `X-Penpal-Token`.
    Handles both standard HTTP header names and WSGI `HTTP_*` META keys.
    """
    lowered = {str(k).lower(): str(v) for k, v in headers.items() if v is not None}
    auth = lowered.get("authorization") or lowered.get("http_authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    custom = (
        lowered.get("x-penpal-token")
        or lowered.get("http_x_penpal_token")
        or ""
    ).strip()
    return custom or None


def _client_token(request) -> str | None:
    meta = getattr(request, "META", None)
    if isinstance(meta, Mapping):
        return _token_from_headers(meta)
    headers = getattr(request, "headers", None)
    if isinstance(headers, Mapping):
        return _token_from_headers(headers)
    return None


def _token_is_valid(candidate: str, configured: set[str]) -> bool:
    return any(
        secrets.compare_digest(candidate, known)
        for known in configured
    )


def _prune(hits: deque, window: int, now: float) -> None:
    while hits and now - hits[0] > window:
        hits.popleft()


def _rate_limit_key(token: str, headers: Mapping[str, Any]) -> str:
    """
    Build the rate-limit bucket key.

    When all App Store devices share a bundled `PENPAL_ACCESS_TOKEN`, keying
    solely on `token` would cause one heavy user to rate-limit other users.
    We sub-key by Cloudflare's verified `CF-Connecting-IP` (or the app's
    `X-Penpal-Device-Id`) when present, while preserving pure-token keying
    when neither header is sent.
    """
    lowered = {str(k).lower(): str(v) for k, v in headers.items() if v is not None}
    client_id = (
        lowered.get("cf-connecting-ip")
        or lowered.get("http_cf_connecting_ip")
        or lowered.get("x-penpal-device-id")
        or lowered.get("http_x_penpal_device_id")
        or ""
    ).strip()
    return f"{token}:{client_id[:64]}" if client_id else token


def check_headers(
    headers: Mapping[str, Any],
) -> tuple[int, dict[str, str], dict[str, Any]] | None:
    """
    Framework-agnostic access & rate-limit guard for Cloudflare Workers and HTTP routers.
    Returns `(status_code, extra_headers, json_body)` when denied, else `None`.
    """
    configured = set(getattr(settings, "PENPAL_TOKENS", set()) or set())
    if not configured:
        return None

    token = _token_from_headers(headers)
    if not token or not _token_is_valid(token, configured):
        return (401, {}, {"error": "Invalid or missing access token."})

    bucket_key = _rate_limit_key(token, headers)
    now = time.time()
    per_minute = int(getattr(settings, "RATE_LIMIT_PER_MINUTE", 20))
    per_day = int(getattr(settings, "RATE_LIMIT_PER_DAY", 500))
    with _lock:
        minute, day = _minute_hits[bucket_key], _day_hits[bucket_key]
        _prune(minute, MINUTE, now)
        _prune(day, DAY, now)

        if len(minute) >= per_minute:
            retry = max(1, int(MINUTE - (now - minute[0])) + 1)
            return (
                429,
                {"Retry-After": str(retry)},
                {"error": "Too many requests — give it a moment."},
            )

        if len(day) >= per_day:
            retry = max(1, int(DAY - (now - day[0])) + 1)
            return (
                429,
                {"Retry-After": str(retry)},
                {"error": "Daily limit reached."},
            )

        minute.append(now)
        day.append(now)
    return None


def check(request):
    """
    Django REST Framework wrapper around `check_headers`.
    Returns an error `Response` when the request must be refused, else `None`.
    """
    from rest_framework.response import Response

    meta = getattr(request, "META", None) or getattr(request, "headers", None) or {}
    denied = check_headers(meta)
    if denied is None:
        return None
    status_code, extra_headers, payload = denied
    response = Response(payload, status=status_code)
    for k, v in extra_headers.items():
        response[k] = v
    return response


def reset() -> None:
    """Test hook."""
    with _lock:
        _minute_hits.clear()
        _day_hits.clear()
