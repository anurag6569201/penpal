"""
Framework-agnostic configuration for the Penpal brain.

Works identically inside:
1. Cloudflare Python Workers (`WorkerEntrypoint.env` bound per request)
2. Standalone Python worker server (`os.environ` / `.env`)
3. Django test suite (`django.conf.settings` + `@override_settings`)
"""

from __future__ import annotations

import contextvars
from contextlib import contextmanager
import os
import sys
from typing import Any

_worker_env: contextvars.ContextVar[dict[str, Any] | None] = contextvars.ContextVar(
    "penpal_worker_env", default=None
)

_DEFAULTS: dict[str, Any] = {
    "GEMINI_API_KEY": "",
    "GEMINI_MODEL": "gemini-2.5-flash",
    "GEMINI_VERIFY_MODEL": "",
    "GEMINI_IMPORT_MODEL": "",
    "GEMINI_ILLUSTRATOR_MODEL": "",
    "GEMINI_IMAGE_MODEL": "gemini-2.5-flash-image",
    "ILLUSTRATOR_TRACE_ENABLED": True,
    "GEMINI_LANGUAGE_MODEL": "",
    "GEMINI_DEBATE_MODEL": "",
    "GEMINI_VISION_MODEL": "",
    "PENPAL_TOKENS": set(),
    "RATE_LIMIT_PER_MINUTE": 20,
    "RATE_LIMIT_PER_DAY": 500,
    "PENPAL_DEV": False,
}


def parse_tokens(raw: Any) -> set[str]:
    if isinstance(raw, (set, list, tuple, frozenset)):
        return {str(t).strip() for t in raw if str(t).strip()}
    if isinstance(raw, str):
        return {t.strip() for t in raw.split(",") if t.strip()}
    return set()


def _coerce(name: str, value: Any) -> Any:
    if value is None:
        return None
    if name == "PENPAL_TOKENS":
        return parse_tokens(value)
    if name in ("ILLUSTRATOR_TRACE_ENABLED", "PENPAL_DEV"):
        if isinstance(value, bool):
            return value
        return str(value).strip().lower() not in ("0", "false", "no", "off", "")
    if name in ("RATE_LIMIT_PER_MINUTE", "RATE_LIMIT_PER_DAY"):
        try:
            return int(value)
        except (TypeError, ValueError):
            return _DEFAULTS[name]
    return str(value)


def extract_env_dict(env: Any) -> dict[str, Any]:
    """Convert a Cloudflare Worker `env` object or mapping into a Python dict."""
    if env is None:
        return {}
    if isinstance(env, dict):
        out: dict[str, Any] = {}
        for k in _DEFAULTS:
            if k in env and env[k] is not None:
                out[k] = _coerce(k, env[k])
        return out
    out = {}
    for k in _DEFAULTS:
        try:
            val = getattr(env, k, None)
        except Exception:  # noqa: BLE001
            val = None
        if val is not None:
            # Guard against JS `undefined` bridged via Pyodide FFI
            if type(val).__name__ == "JsUndefined":
                continue
            out[k] = _coerce(k, val)
    return out


@contextmanager
def bind_worker_env(env: Any):
    """Bind Cloudflare Worker `self.env` for the duration of a request."""
    extracted = extract_env_dict(env)
    token = _worker_env.set(extracted)
    try:
        yield extracted
    finally:
        _worker_env.reset(token)


def _django_settings():
    if "django.conf" not in sys.modules:
        return None
    try:
        from django.conf import settings as dj_settings
        if dj_settings.configured:
            return dj_settings
    except Exception:  # noqa: BLE001
        return None
    return None


class RuntimeSettings:
    """
    Drop-in proxy for `settings.<NAME>` that resolves from:
    1. Bound Cloudflare Worker `env` (if inside a Worker fetch handler)
    2. Configured `django.conf.settings` (if running under Django / `manage.py test`)
    3. `os.environ`
    4. `_DEFAULTS`
    """

    def __getattr__(self, name: str) -> Any:
        bound = _worker_env.get()
        if bound and name in bound:
            return bound[name]

        dj = _django_settings()
        if dj is not None and hasattr(dj, name):
            return getattr(dj, name)

        if name in os.environ:
            val = os.environ[name]
            if name == "ILLUSTRATOR_TRACE_ENABLED":
                return val.strip().lower() not in ("0", "false", "no", "off")
            coerced = _coerce(name, val)
            if coerced is not None:
                return coerced

        if name in _DEFAULTS:
            default = _DEFAULTS[name]
            return set(default) if isinstance(default, set) else default

        raise AttributeError(f"RuntimeSettings has no attribute {name!r}")


runtime_settings = RuntimeSettings()
