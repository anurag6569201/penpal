"""SymPy compute engine — exact math the LLM can trust.

The Mathematician pipeline uses this in two ways:

1. cas_hint(message)  — before the solve call. If the (OCR-flavoured) input
   parses cleanly, SymPy solves/evaluates it EXACTLY and the result is
   injected into the model's context as ground truth, so the LLM writes the
   steps around a guaranteed-correct answer.
2. It never blocks a reply: every entry point is wrapped in a hard timeout
   and broad exception handling, returning "" / None on any trouble.

No exec/eval of model output — only sympy.parsing of math expressions with a
restricted symbol table, so nothing here can run arbitrary code.
"""

from __future__ import annotations

import concurrent.futures
import logging
import re

logger = logging.getLogger(__name__)

try:  # sympy is optional — the pipeline degrades gracefully without it.
    import sympy
    from sympy import (
        Eq, N, Symbol, diff, factorial, integrate, limit, nsimplify, oo,
        simplify, solveset, sqrt, symbols,
    )
    from sympy.parsing.sympy_parser import (
        convert_xor, implicit_multiplication_application, parse_expr,
        standard_transformations,
    )

    SYMPY_AVAILABLE = True
except Exception:  # pragma: no cover — missing dependency
    SYMPY_AVAILABLE = False

# Hard wall-clock budget for any single CAS attempt (seconds). Handwriting-
# scale problems solve in milliseconds; anything slower isn't worth the wait.
CAS_TIMEOUT = 4.0

_TRANSFORMS = None
_LOCALS = None


def _setup():
    global _TRANSFORMS, _LOCALS
    if _TRANSFORMS is not None:
        return
    _TRANSFORMS = standard_transformations + (
        implicit_multiplication_application,  # 2x, 3(x+1), x y
        convert_xor,                          # ^ means power, not xor
    )
    x, y, z, a, b, c, n, t, u, v, w = symbols("x y z a b c n t u v w")
    _LOCALS = {
        "x": x, "y": y, "z": z, "a": a, "b": b, "c": c,
        "n": n, "t": t, "u": u, "v": v, "w": w,
        "e": sympy.E, "pi": sympy.pi, "oo": oo, "inf": oo,
        "sqrt": sympy.sqrt, "cbrt": sympy.cbrt, "root": sympy.root,
        "sin": sympy.sin, "cos": sympy.cos, "tan": sympy.tan,
        "asin": sympy.asin, "acos": sympy.acos, "atan": sympy.atan,
        "arcsin": sympy.asin, "arccos": sympy.acos, "arctan": sympy.atan,
        "sec": sympy.sec, "csc": sympy.csc, "cot": sympy.cot,
        "sinh": sympy.sinh, "cosh": sympy.cosh, "tanh": sympy.tanh,
        "log": sympy.log, "ln": sympy.log, "exp": sympy.exp,
        "log10": lambda arg: sympy.log(arg, 10),
        "log2": lambda arg: sympy.log(arg, 2),
        "abs": sympy.Abs, "Abs": sympy.Abs,
        "factorial": factorial, "gcd": sympy.gcd, "lcm": sympy.lcm,
        "floor": sympy.floor, "ceil": sympy.ceiling, "ceiling": sympy.ceiling,
        "binomial": sympy.binomial, "C": sympy.binomial,
        "Sum": sympy.Sum, "sum": sympy.Sum,
        "diff": sympy.diff, "integrate": sympy.integrate,
        "limit": sympy.limit, "Matrix": sympy.Matrix,
        "mod": sympy.Mod, "Mod": sympy.Mod,
    }


# ---------------------------------------------------------------------------
# Normalisation — tolerate handwriting / OCR quirks
# ---------------------------------------------------------------------------

_UNICODE_MAP = {
    "×": "*", "·": "*", "∙": "*", "÷": "/", "−": "-", "–": "-",
    "√": "sqrt", "π": "pi", "∞": "oo", "°": " deg", "≤": "<=", "≥": ">=",
    "≠": "!=", "²": "^2", "³": "^3", "¹": "^1", "⁴": "^4", "⁵": "^5",
    "½": "(1/2)", "⅓": "(1/3)", "¼": "(1/4)", "¾": "(3/4)", "⅔": "(2/3)",
}


def normalize(text: str) -> str:
    """Plain-ASCII cleanup of a handwritten/OCR'd math string."""
    s = _strip_trailing_eq((text or "").strip())
    for k, v in _UNICODE_MAP.items():
        s = s.replace(k, v)
    # "5! " factorial: sympy parser handles via factorial() — rewrite n! forms.
    s = re.sub(r"(\d+)\s*!", r"factorial(\1)", s)
    # percentage: "20% of 50" -> "(20/100)*50" ; bare "20%" -> "(20/100)"
    s = re.sub(r"(\d+(?:\.\d+)?)\s*%\s*of\s*", r"(\1/100)*", s, flags=re.I)
    s = re.sub(r"(\d+(?:\.\d+)?)\s*%", r"(\1/100)", s)
    # "mod" as infix: 2^10 mod 7 -> Mod(2^10, 7)
    m = re.match(r"^\s*(.+?)\s+mod\s+(.+?)\s*$", s, flags=re.I)
    if m:
        s = f"Mod({m.group(1)}, {m.group(2)})"
    return s.strip()


def _strip_trailing_eq(s: str) -> str:
    return s[:-1].strip() if s.endswith("=") else s


def _parse(s: str):
    _setup()
    return parse_expr(s, transformations=_TRANSFORMS, local_dict=_LOCALS,
                      evaluate=True)


# ---------------------------------------------------------------------------
# Core attempts (run inside the timeout wrapper)
# ---------------------------------------------------------------------------

def _fmt(expr) -> str:
    """Exact form, plus decimal when it adds information."""
    try:
        exact = sympy.sstr(expr)
        if expr.free_symbols or getattr(expr, "is_Integer", False):
            return exact
        num_s = sympy.sstr(N(expr, 6))
        if num_s != exact:
            return f"{exact} ≈ {num_s}"
        return exact
    except Exception:
        return sympy.sstr(expr)


def _attempt(message: str) -> str:
    """Return a compact trusted-results block, or '' if nothing parseable."""
    raw = normalize(message)
    raw = _strip_trailing_eq(raw)
    if not raw or len(raw) > 300:
        return ""
    # Reject inputs that are mostly words — CAS is for symbolic input.
    _setup()
    words = re.findall(r"[A-Za-z]{3,}", raw)
    fn_names = {k.lower() for k in _LOCALS} | {"deg", "mod", "factorial"}
    if sum(1 for wd in words if wd.lower() not in fn_names) >= 2:
        return ""

    lines: list[str] = []

    # Equation (single "=" with content on both sides) or system split by ","/";"
    if "=" in raw and not any(op in raw for op in ("<=", ">=", "!=", "==")):
        parts = [p.strip() for p in re.split(r"[;,]", raw) if p.strip()]
        try:
            eqs, free = [], set()
            for p in parts:
                lhs, rhs = p.split("=", 1)
                eq = Eq(_parse(lhs), _parse(rhs))
                eqs.append(eq)
                free |= eq.free_symbols
            free = sorted(free, key=lambda s_: s_.name)
            if not free:
                verdict = all(bool(simplify(e.lhs - e.rhs) == 0) for e in eqs)
                lines.append(f"identity check: {'TRUE' if verdict else 'FALSE'}")
            elif len(eqs) == 1 and len(free) == 1:
                sol = sympy.solve(eqs[0], free[0])
                lines.append(
                    f"solve for {free[0]}: "
                    + (", ".join(_fmt(s_) for s_ in sol) if sol else "no solution")
                )
            else:
                sol = sympy.solve(eqs, free, dict=True)
                if sol:
                    pretty = "; ".join(
                        ", ".join(f"{k}={_fmt(v)}" for k, v in d.items())
                        for d in sol
                    )
                    lines.append(f"solve system: {pretty}")
        except Exception:
            pass
    else:
        # Plain expression: evaluate / simplify.
        try:
            expr = _parse(raw)
            if expr.free_symbols:
                simp = simplify(expr)
                if sympy.sstr(simp) != sympy.sstr(expr):
                    lines.append(f"simplifies to: {_fmt(simp)}")
                # bonus: derivative w.r.t. the single variable
                if len(expr.free_symbols) == 1:
                    v_ = next(iter(expr.free_symbols))
                    lines.append(f"d/d{v_}: {_fmt(diff(expr, v_))}")
            else:
                lines.append(f"value: {_fmt(expr)}")
        except Exception:
            pass

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def cas_hint(message: str) -> str:
    """
    Best-effort exact results for the given problem, formatted as a short
    block the solver prompt treats as ground truth. "" when unavailable.
    Never raises; bounded by CAS_TIMEOUT.
    """
    if not SYMPY_AVAILABLE:
        return ""
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(_attempt, message)
            return fut.result(timeout=CAS_TIMEOUT) or ""
    except concurrent.futures.TimeoutError:
        logger.info("CAS hint timed out for %r", message[:80])
        return ""
    except Exception:
        logger.exception("CAS hint failed")
        return ""
