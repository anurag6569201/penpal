#!/usr/bin/env python3
"""
Synchronize runtime `chat/*.py` modules into `src/chat/` and prune non-runtime
files from `python_modules/` so the Cloudflare Python Worker bundle stays well
below Cloudflare's 64 MiB uncompressed Worker size limit.
"""

from __future__ import annotations

from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent.parent
CHAT_SRC = ROOT / "chat"
CHAT_DEST = ROOT / "src" / "chat"
PYTHON_MODULES = ROOT / "python_modules"

RUNTIME_MODULES = (
    "__init__.py",
    "access.py",
    "config.py",
    "gemini.py",
    "mathengine.py",
    "prompts.py",
    "router.py",
    "routing.py",
    "telemetry.py",
    "tracer.py",
)

# Unused heavy subpackages / build tools inside python_modules that are never
# imported by Penpal at runtime (e.g., Vertex AI mTLS cryptography, gaos,
# numpy f2py, and unused sympy physics/codegen subpackages).
# Note: sympy/plotting is intentionally kept because sympy/__init__.py imports it.
PRUNE_REL_DIRS = (
    "cryptography",
    "cffi",
    "pycparser",
    "pyasn1",
    "pyasn1_modules",
    "google/genai/_gaos",
    "latex2sympy2_extended",
    "antlr4",
    "numpy/f2py",
    "numpy/doc",
    "numpy/testing/tests",
    "sympy/physics",
    "sympy/categories",
    "sympy/codegen",
    "sympy/crypto",
    "sympy/diffgeom",
    "sympy/galgebra",
    "sympy/holonomic",
    "sympy/liealgebras",
    "sympy/stats",
    "sympy/unify",
    "sympy/vector",
)


def sync() -> None:
    CHAT_DEST.mkdir(parents=True, exist_ok=True)
    for name in RUNTIME_MODULES:
        shutil.copy2(CHAT_SRC / name, CHAT_DEST / name)

    if not PYTHON_MODULES.exists():
        return

    # 1. Remove unused subpackages
    for rel in PRUNE_REL_DIRS:
        target = PYTHON_MODULES / rel
        if target.exists():
            shutil.rmtree(target, ignore_errors=True)

    # 2. Remove embedded test suites and Cython/type stub files (*.pyi, *.pxd, *.pyc)
    for path in list(PYTHON_MODULES.rglob("*")):
        if not path.exists():
            continue
        if path.is_dir() and path.name in ("tests", "__pycache__"):
            shutil.rmtree(path, ignore_errors=True)
        elif path.is_file() and path.suffix in (".pyi", ".pxd", ".pyc"):
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    sync()
