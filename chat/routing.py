"""
PEN-29 / PEN-27 — model routing and cost accounting.

Two observations drive this:

1. **Most problems don't need a strong model.** "5+5", "sqrt(144)", "x^2-5x+6=0"
   are solved EXACTLY by the CAS before any model is called. Sending those to a
   reasoning model is paying reasoning prices for transcription.

2. **Verification doubled our per-solve cost.** That was the right trade for
   correctness, but it was never measured. `estimate_cost` makes it visible so
   the trade can be re-examined with numbers instead of vibes.

The routing rule is deliberately conservative: downgrade only when the CAS has
already produced the exact answer, so the model's job is reduced to writing
known-correct steps around a known-correct result. Anything the CAS could not
solve — word problems, proofs, anything with an image — keeps the strong model.
Saving money by getting maths wrong is not a saving.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from django.conf import settings

# Rough per-million-token prices (USD). Only the RATIO matters here — this
# exists to compare routes and spot runaway spend, not to bill anyone.
PRICING = {
    "flash-lite": (0.10, 0.40),
    "flash": (0.30, 2.50),
    "pro": (1.25, 10.00),
}


def _tier(model: str) -> str:
    name = (model or "").lower()
    if "lite" in name:
        return "flash-lite"
    if "pro" in name:
        return "pro"
    return "flash"


@dataclass(frozen=True)
class Route:
    model: str
    reason: str
    #: True when the CAS already holds the exact answer, so the model is only
    #: dressing it — fewer tokens needed, and verification may be skippable.
    cas_certain: bool = False
    #: The exact value SymPy proved, e.g. "4". The pipeline checks the model's
    #: final answer against this before skipping the referee.
    cas_value: str = ""

    @property
    def skip_verification(self) -> bool:
        """
        The referee exists to catch a model inventing an answer. When SymPy
        computed the answer exactly, re-deriving it is paying twice for the
        same certainty — PROVIDED the model actually reproduced it. The
        pipeline gates this on an agreement check; a model that ignores the
        [CAS] block still gets refereed.
        """
        return self.cas_certain and bool(self.cas_value)

    @property
    def max_output_tokens(self) -> int:
        # Thinking-class models spend output tokens on reasoning BEFORE the
        # visible text; 1200 could be consumed entirely and return an empty
        # draft (→ 503 / vanished reply). The prompt bounds the visible
        # length; this only needs to cover reasoning headroom.
        return 4000 if self.cas_certain else 8000


# Problems the CAS solves outright AND that need no explanation to be useful.
# A bare arithmetic evaluation is the clearest case: the answer is the whole
# reply. Solving an equation still wants steps, so it is excluded.
_TRIVIAL_CAS = re.compile(r"^(value|identity check):", re.M)


def choose(message: str, cas_hint: str = "", has_image: bool = False,
           math_detail: str = "compact") -> Route:
    """Pick a model for this request."""
    strong = settings.GEMINI_MODEL
    cheap = getattr(settings, "GEMINI_FAST_MODEL", "") or strong

    # Images always get the strong model: reading handwriting is the hardest
    # thing we ask, and a misread problem is a wrong answer that LOOKS right.
    if has_image:
        return Route(strong, "image input")

    # Proofs need reasoning, whatever the CAS found.
    if (math_detail or "").strip().lower() == "proof":
        return Route(strong, "proof detail level")

    match = _TRIVIAL_CAS.search(cas_hint or "")
    if match:
        # Exact value in hand, and the reply is essentially that value.
        # Strip any "≈ 0.833" tail: the exact form is what must be reproduced.
        value = cas_hint[match.end():].split("\n")[0].split("≈")[0].strip()
        model = cheap if cheap != strong else strong
        return Route(model, "CAS solved it exactly",
                     cas_certain=True, cas_value=value)

    return Route(strong, "default")


def estimate_cost(model: str, prompt_tokens: int, output_tokens: int) -> float:
    """USD estimate for one call."""
    inp, out = PRICING[_tier(model)]
    return (prompt_tokens * inp + output_tokens * out) / 1_000_000


def usage_from(response) -> tuple[int, int]:
    """
    (prompt_tokens, output_tokens) from a Gemini response. Returns (0, 0) when
    the SDK didn't report usage — accounting must never break a reply.
    """
    try:
        meta = getattr(response, "usage_metadata", None)
        if meta is None:
            return (0, 0)
        prompt = int(getattr(meta, "prompt_token_count", 0) or 0)
        # Thinking tokens are billed as output and are a large share of the
        # cost on reasoning models, so they must be counted.
        output = int(getattr(meta, "candidates_token_count", 0) or 0)
        output += int(getattr(meta, "thoughts_token_count", 0) or 0)
        return (prompt, output)
    except Exception:  # pragma: no cover
        return (0, 0)
