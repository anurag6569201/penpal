"""
PEN-36 — image → ordered pen-stroke tracer.

Turns a raster (a Gemini line-art render, or later any picked image) into the
same ordered `outline`/`detail` path plan the Illustrator already draws. The
output is deliberately in the *raw* 0..1000 shape that `gemini._clean_illustration`
validates and bounds, so every cap, safety check and normalisation lives in one
place and this module never needs to know the on-page geometry.

Why centre-lines, not `potrace`: potrace traces the *outline* of a filled black
region, so a single drawn line comes back as two parallel strokes wrapping it.
A pen draws one line once. Skeletonising to a 1px medial axis and walking that
into polylines makes one drawn line == one pen stroke — the whole point of a
"traced, not pasted" sketch.

Pipeline: line extraction (threshold for clean line art, XDoG for photos) →
skeletonize → skeleton graph walk → Ramer-Douglas-Peucker → order biggest
silhouettes first.
"""
from __future__ import annotations

import math
from typing import Any

import cv2
import numpy as np
from skimage.morphology import skeletonize

# Mirror _clean_illustration's caps so we hand it something already in range.
_MAX_STROKES = 120
_MAX_PTS_PER_STROKE = 180
_MIN_STROKE_PIXELS = 12          # drop specks and raster hatching fragments
_RDP_EPS = 1.6                   # px; detail vs point-count trade-off
_OUTLINE_FRACTION = 0.45         # a stroke is "outline" if its bbox diagonal is
                                 # >= this fraction of the biggest one
_WORK_MAX_SIDE = 900             # cap working resolution for speed

_NB = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]

_DEFAULT_REFUSAL = "I couldn't find clean lines to trace in that image."


# --------------------------------------------------------------------------
# 1. line extraction
# --------------------------------------------------------------------------
def _xdog(gray: np.ndarray, sigma=0.8, k=4.5, tau=0.98, phi=10.0) -> np.ndarray:
    """eXtended Difference-of-Gaussians — an inked-looking line map for photos."""
    g = gray.astype(np.float32) / 255.0
    g1 = cv2.GaussianBlur(g, (0, 0), sigma)
    g2 = cv2.GaussianBlur(g, (0, 0), sigma * k)
    d = g1 - tau * g2
    e = np.where(d >= 0, 1.0, 1.0 + np.tanh(phi * d))
    return (e * 255).astype(np.uint8)


def _line_mask(img_bgr: np.ndarray, mode: str = "auto") -> np.ndarray:
    """Return a boolean mask: True where ink lines are."""
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    if mode == "auto":
        # Line art is mostly white with thin dark strokes -> few dark pixels.
        dark_frac = float((gray < 128).mean())
        mode = "lineart" if dark_frac < 0.25 else "photo"
    if mode == "photo":
        gray = _xdog(gray)
    # Otsu threshold -> ink is dark.
    _, bw = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    bw = cv2.morphologyEx(bw, cv2.MORPH_CLOSE,
                          cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    return bw > 0


# --------------------------------------------------------------------------
# 2. skeleton -> polylines
# --------------------------------------------------------------------------
def _skeleton_to_paths(skel: np.ndarray) -> list[list[tuple[int, int]]]:
    """Walk a 1px skeleton into polylines, in (x, y)."""
    pts = set(map(tuple, np.argwhere(skel)))  # (row, col)

    def nbrs(p):
        r, c = p
        return [(r + dr, c + dc) for dr, dc in _NB if (r + dr, c + dc) in pts]

    deg = {p: len(nbrs(p)) for p in pts}
    specials = [p for p in pts if deg[p] != 2]   # endpoints (1) + junctions (>=3)
    used: set = set()

    def edge(a, b):
        return (a, b) if a <= b else (b, a)

    paths: list[list[tuple[int, int]]] = []

    # 3a. open edges between endpoints / junctions
    for s in specials:
        for n in nbrs(s):
            if edge(s, n) in used:
                continue
            path, prev, cur = [s, n], s, n
            used.add(edge(s, n))
            while deg[cur] == 2:
                nxt = [q for q in nbrs(cur) if q != prev]
                if not nxt:
                    break
                nxt = nxt[0]
                used.add(edge(cur, nxt))
                path.append(nxt)
                prev, cur = cur, nxt
            paths.append(path)

    # 3b. isolated closed loops (all degree-2, never touch a special node)
    for p in pts:
        for n in nbrs(p):
            if edge(p, n) in used:
                continue
            path, prev, cur = [p, n], p, n
            used.add(edge(p, n))
            while cur != p and deg[cur] == 2:
                nxt = [q for q in nbrs(cur)
                       if q != prev and edge(cur, q) not in used]
                if not nxt:
                    break
                nxt = nxt[0]
                used.add(edge(cur, nxt))
                path.append(nxt)
                prev, cur = cur, nxt
            paths.append(path)

    return [[(c, r) for (r, c) in p] for p in paths]


# --------------------------------------------------------------------------
# 3. simplify
# --------------------------------------------------------------------------
def _rdp(points: list, eps: float) -> list:
    # Pure-scalar perpendicular distance: NumPy 2.3 removed the 2-D np.cross,
    # and the explicit form is both version-proof and faster in this loop.
    if len(points) < 3:
        return points
    ax, ay = points[0]
    bx, by = points[-1]
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    if length == 0.0:
        dists = [math.hypot(px - ax, py - ay) for px, py in points]
    else:
        dists = [abs(dx * (py - ay) - dy * (px - ax)) / length
                 for px, py in points]
    i = max(range(len(points)), key=dists.__getitem__)
    if dists[i] > eps:
        return _rdp(points[:i + 1], eps)[:-1] + _rdp(points[i:], eps)
    return [points[0], points[-1]]


def _stroke_len(poly: list) -> float:
    return sum(math.hypot(poly[i + 1][0] - poly[i][0], poly[i + 1][1] - poly[i][1])
               for i in range(len(poly) - 1))


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
def trace(image_bytes: bytes, label: str = "illustration",
          mode: str = "auto") -> dict[str, Any]:
    """
    Trace `image_bytes` into a raw stroke plan for `_clean_illustration`.

    Returns `{"kind": "strokes", "label", "strokes": [{"role", "points"}]}` with
    points on a 0..1000 canvas, or `{"kind": "refusal", "message"}` when there is
    nothing traceable — the same honest-degradation contract as the model path.
    """
    arr = np.frombuffer(image_bytes, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        return {"kind": "refusal", "message": "That image could not be read."}

    h, w = img.shape[:2]
    scale = min(1.0, _WORK_MAX_SIDE / max(h, w))
    if scale < 1.0:
        img = cv2.resize(img, (int(w * scale), int(h * scale)),
                         interpolation=cv2.INTER_AREA)
        h, w = img.shape[:2]

    skel = skeletonize(_line_mask(img, mode))
    polys = _skeleton_to_paths(skel)

    strokes: list[dict[str, Any]] = []
    for poly in polys:
        if len(poly) < 2 or _stroke_len(poly) < _MIN_STROKE_PIXELS:
            continue
        simp = _rdp(poly, _RDP_EPS)
        if len(simp) > _MAX_PTS_PER_STROKE:
            idx = np.linspace(0, len(simp) - 1, _MAX_PTS_PER_STROKE).astype(int)
            simp = [simp[i] for i in idx]
        xs = [p[0] for p in simp]
        ys = [p[1] for p in simp]
        diag = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
        strokes.append({"poly": simp, "diag": diag})

    if not strokes:
        return {"kind": "refusal", "message": _DEFAULT_REFUSAL}

    # Order like a hand: biggest silhouettes first, small detail last.
    strokes.sort(key=lambda s: s["diag"], reverse=True)
    strokes = strokes[:_MAX_STROKES]
    biggest = strokes[0]["diag"] or 1.0

    out = []
    for s in strokes:
        role = "outline" if s["diag"] >= _OUTLINE_FRACTION * biggest else "detail"
        # 0..1000 canvas — the raw shape _clean_illustration expects as input.
        points = [[round(x / w * 1000, 2), round(y / h * 1000, 2)]
                  for x, y in s["poly"]]
        out.append({"role": role, "points": points})

    return {"kind": "strokes", "label": (label or "illustration")[:120], "strokes": out}
