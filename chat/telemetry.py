"""
PEN-04 — verification telemetry.

The lesson of BB-03: the referee's JSON was truncated on every boxed solve,
the pipeline correctly failed open, and verification was therefore disabled
for an unknown length of time **while continuing to look like it worked**.
Every answer came back appearing verified. Nothing was verifying it.

A fail-open path is the right engineering decision — a broken checker must
never take down a reply. But a safety net nobody can observe is not a safety
net. So every degradation records itself here, and `/api/health/` reports it.

Deliberately in-process and lock-guarded rather than a metrics backend:
Penpal's brain is a single small server, and a dependency-free counter that
always works beats a sophisticated one that isn't wired up.
"""

from __future__ import annotations

import threading
import time
from collections import Counter, deque

# Rolling window of recent events. Bounded so it can never grow unbounded in
# a long-running process.
_MAX_EVENTS = 200

_lock = threading.Lock()
_counts: Counter = Counter()
_recent: deque = deque(maxlen=_MAX_EVENTS)
_started = time.time()


# Event names. Kept as constants so a typo can't silently create a new metric
# that nobody is watching.
SOLVE_STARTED = "solve.started"
SOLVE_COMPLETED = "solve.completed"

VERIFY_CORRECT = "verify.correct"          # referee approved the draft
VERIFY_WRONG = "verify.wrong"              # referee caught an error
VERIFY_CORRECTED = "verify.corrected"      # correction pass produced a fix
VERIFY_SALVAGED = "verify.salvaged_json"   # verdict recovered from bad JSON
VERIFY_FAILED_OPEN = "verify.failed_open"  # checker broke; draft returned

CAS_HIT = "cas.hit"                        # exact result injected
CAS_MISS = "cas.miss"                      # nothing parseable
CAS_TIMEOUT = "cas.timeout"                # exceeded the time budget

# Degradations — things that mean we are quietly running below spec.
DEGRADED = {VERIFY_FAILED_OPEN, CAS_TIMEOUT}


_cost: dict[str, float] = {"usd": 0.0, "prompt_tokens": 0.0, "output_tokens": 0.0}
_by_model: Counter = Counter()


def record_usage(model: str, prompt_tokens: int, output_tokens: int,
                 usd: float) -> None:
    """PEN-27 — per-call cost accounting. Never raises."""
    try:
        with _lock:
            _cost["usd"] += usd
            _cost["prompt_tokens"] += prompt_tokens
            _cost["output_tokens"] += output_tokens
            _by_model[model] += 1
    except Exception:  # pragma: no cover
        pass


def record(event: str, detail: str = "") -> None:
    """Never raises. Telemetry must not be able to break a reply."""
    try:
        with _lock:
            _counts[event] += 1
            if event in DEGRADED or event == VERIFY_SALVAGED:
                _recent.append({
                    "event": event,
                    "detail": detail[:200],
                    "at": time.time(),
                })
    except Exception:  # pragma: no cover
        pass


def snapshot() -> dict:
    """Current counters plus a computed health verdict."""
    with _lock:
        counts = dict(_counts)
        recent = list(_recent)

    solves = counts.get(SOLVE_COMPLETED, 0)
    failed_open = counts.get(VERIFY_FAILED_OPEN, 0)
    verified = counts.get(VERIFY_CORRECT, 0) + counts.get(VERIFY_WRONG, 0)

    # Share of solves that actually got a usable verdict. This is THE number:
    # if it drops, we are shipping unverified answers that look verified.
    attempted = verified + failed_open
    coverage = (verified / attempted) if attempted else 1.0

    if attempted == 0:
        status = "idle"
    elif coverage >= 0.95:
        status = "healthy"
    elif coverage >= 0.5:
        status = "degraded"
    else:
        status = "unverified"

    with _lock:
        cost = dict(_cost)
        by_model = dict(_by_model)

    return {
        "status": status,
        "verification_coverage": round(coverage, 3),
        "cost": {
            "usd_total": round(cost["usd"], 4),
            "usd_per_solve": round(cost["usd"] / solves, 5) if solves else 0.0,
            "prompt_tokens": int(cost["prompt_tokens"]),
            "output_tokens": int(cost["output_tokens"]),
            "calls_by_model": by_model,
        },
        "solves": solves,
        "verified": verified,
        "failed_open": failed_open,
        "caught_errors": counts.get(VERIFY_WRONG, 0),
        "corrections_applied": counts.get(VERIFY_CORRECTED, 0),
        "salvaged_verdicts": counts.get(VERIFY_SALVAGED, 0),
        "cas_hits": counts.get(CAS_HIT, 0),
        "cas_misses": counts.get(CAS_MISS, 0),
        "cas_timeouts": counts.get(CAS_TIMEOUT, 0),
        "uptime_seconds": int(time.time() - _started),
        "recent_degradations": recent[-10:],
        "counts": counts,
    }


def reset() -> None:
    """Test hook."""
    with _lock:
        _counts.clear()
        _recent.clear()
        _by_model.clear()
        for key in _cost:
            _cost[key] = 0.0
