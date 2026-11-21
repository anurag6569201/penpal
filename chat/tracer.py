"""
PEN-36 — image → ordered pen-stroke tracer (Cloudflare Worker / Pyodide ready).

Turns a raster (a Gemini line-art render, or any picked image) into the same
ordered `outline`/`detail` path plan the Illustrator draws. Built exclusively on
Pillow + NumPy (no OpenCV or scikit-image C++ dependencies) so it runs within
Cloudflare Python Workers' memory and bundle limits while preserving 1px medial
axis skeletonization.

Pipeline: line extraction (Otsu threshold for clean line art, XDoG for photos) →
Zhang–Suen skeletonize → skeleton graph walk → Ramer-Douglas-Peucker → order
biggest silhouettes first.
"""
from __future__ import annotations

from dataclasses import dataclass
import io
import math
from typing import Any

import numpy as np
from PIL import Image, ImageFilter

_OUTLINE_FRACTION = 0.45         # a stroke is "outline" if its bbox diagonal is
                                 # >= this fraction of the biggest one


@dataclass(frozen=True)
class TraceProfile:
    """Bounded quality/cost envelope shared with the API cleaner."""

    max_strokes: int
    max_points_per_stroke: int
    max_total_points: int
    min_stroke_pixels: float
    rdp_epsilon: float
    work_max_side: int


# Detailed is intentionally much less destructive, but still bounded: a literal
# "unlimited" trace can turn image noise into tens of thousands of PencilKit
# strokes and freeze the page.
QUALITY_PROFILES = {
    "quick": TraceProfile(
        max_strokes=120,
        max_points_per_stroke=180,
        max_total_points=12_000,
        min_stroke_pixels=12,
        rdp_epsilon=1.6,
        work_max_side=900,
    ),
    "balanced": TraceProfile(
        max_strokes=300,
        max_points_per_stroke=320,
        max_total_points=40_000,
        min_stroke_pixels=6,
        rdp_epsilon=0.9,
        work_max_side=1400,
    ),
    "detailed": TraceProfile(
        max_strokes=600,
        max_points_per_stroke=500,
        max_total_points=100_000,
        min_stroke_pixels=2,
        rdp_epsilon=0.45,
        work_max_side=1800,
    ),
}


def normalize_quality(value: Any, default: str = "detailed") -> str:
    quality = str(value or "").strip().lower()
    return quality if quality in QUALITY_PROFILES else default


def profile_for(quality: Any) -> TraceProfile:
    return QUALITY_PROFILES[normalize_quality(quality)]


_NB = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)]

_DEFAULT_REFUSAL = "I couldn't find clean lines to trace in that image."


# --------------------------------------------------------------------------
# 1. Pure Pillow + NumPy image primitives (replaces OpenCV + scikit-image)
# --------------------------------------------------------------------------
def _gaussian_blur(gray_float: np.ndarray, sigma: float) -> np.ndarray:
    """Separable 1D Gaussian blur in NumPy matching cv2.GaussianBlur(g, (0, 0), sigma)."""
    if sigma <= 0:
        return gray_float
    radius = max(1, int(round(sigma * 3.0)))
    x = np.arange(-radius, radius + 1, dtype=np.float32)
    kernel = np.exp(-(x * x) / (2.0 * sigma * sigma))
    kernel /= kernel.sum()
    padded_h = np.pad(gray_float, ((0, 0), (radius, radius)), mode="reflect")
    horiz = np.apply_along_axis(
        lambda row: np.convolve(row, kernel, mode="valid"), 1, padded_h
    )
    padded_v = np.pad(horiz, ((radius, radius), (0, 0)), mode="reflect")
    vert = np.apply_along_axis(
        lambda col: np.convolve(col, kernel, mode="valid"), 0, padded_v
    )
    return vert.astype(np.float32)


def _xdog(gray: np.ndarray, sigma=0.8, k=4.5, tau=0.98, phi=10.0) -> np.ndarray:
    """eXtended Difference-of-Gaussians — an inked-looking line map for photos."""
    g = gray.astype(np.float32) / 255.0
    g1 = _gaussian_blur(g, sigma)
    g2 = _gaussian_blur(g, sigma * k)
    d = g1 - tau * g2
    e = np.where(d >= 0, 1.0, 1.0 + np.tanh(phi * d))
    return (e * 255).astype(np.uint8)


def _otsu_binary_inv(gray: np.ndarray) -> np.ndarray:
    """
    Matches `cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)`.
    Returns boolean mask where dark ink pixels are True.
    """
    if gray.size == 0:
        return np.zeros_like(gray, dtype=bool)
    min_val = int(gray.min())
    max_val = int(gray.max())
    if min_val == max_val:
        # Uniform image (e.g. blank white canvas -> 255 > 0 -> all False).
        return gray <= 0

    hist = np.bincount(gray.ravel(), minlength=256).astype(np.float64)
    total = float(gray.size)
    sum_all = float(np.dot(np.arange(256, dtype=np.float64), hist))

    weight_bg = 0.0
    sum_bg = 0.0
    best_var = -1.0
    best_thresh = 0

    for t in range(256):
        weight_bg += hist[t]
        if weight_bg == 0.0:
            continue
        weight_fg = total - weight_bg
        if weight_fg == 0.0:
            break
        sum_bg += t * hist[t]
        mean_bg = sum_bg / weight_bg
        mean_fg = (sum_all - sum_bg) / weight_fg
        var_between = weight_bg * weight_fg * (mean_bg - mean_fg) ** 2
        if var_between > best_var:
            best_var = var_between
            best_thresh = t

    return gray <= best_thresh


def _morph_close_ellipse_3x3(mask: np.ndarray) -> np.ndarray:
    """
    Matches `cv2.morphologyEx(bw, cv2.MORPH_CLOSE, getStructuringElement(MORPH_ELLIPSE, (3, 3)))`.
    Note that OpenCV's 3x3 MORPH_ELLIPSE structuring element is a 3x3 cross
    (center + 4 cardinal neighbors), or 3x3 box for diagonal gap bridging.
    """
    if mask.size == 0 or not mask.any():
        return mask.astype(bool)
    # 3x3 cross structuring element (matches cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
    p = np.pad(mask.astype(bool), 1, mode="constant", constant_values=False)
    dilated = (
        p[1:-1, 1:-1]
        | p[:-2, 1:-1]
        | p[2:, 1:-1]
        | p[1:-1, :-2]
        | p[1:-1, 2:]
    )
    # Replicate border on erosion so edge strokes aren't chewed away
    pe = np.pad(dilated, 1, mode="edge")
    eroded = (
        pe[1:-1, 1:-1]
        & pe[:-2, 1:-1]
        & pe[2:, 1:-1]
        & pe[1:-1, :-2]
        & pe[1:-1, 2:]
    )
    return eroded


def _skeletonize(mask: np.ndarray) -> np.ndarray:
    """
    Vectorized Zhang–Suen 1-pixel medial-axis thinning in pure NumPy.
    Replaces `skimage.morphology.skeletonize` with zero C++/SciPy dependencies.
    """
    skel = np.pad(mask.astype(bool), 1, mode="constant", constant_values=False)
    if not skel.any():
        return mask.astype(bool)

    while True:
        changed = False
        for step in (0, 1):
            p2 = skel[:-2, 1:-1]
            p3 = skel[:-2, 2:]
            p4 = skel[1:-1, 2:]
            p5 = skel[2:, 2:]
            p6 = skel[2:, 1:-1]
            p7 = skel[2:, :-2]
            p8 = skel[1:-1, :-2]
            p9 = skel[:-2, :-2]

            b = (
                p2.astype(np.uint8)
                + p3.astype(np.uint8)
                + p4.astype(np.uint8)
                + p5.astype(np.uint8)
                + p6.astype(np.uint8)
                + p7.astype(np.uint8)
                + p8.astype(np.uint8)
                + p9.astype(np.uint8)
            )
            a = (
                ((~p2) & p3).astype(np.uint8)
                + ((~p3) & p4).astype(np.uint8)
                + ((~p4) & p5).astype(np.uint8)
                + ((~p5) & p6).astype(np.uint8)
                + ((~p6) & p7).astype(np.uint8)
                + ((~p7) & p8).astype(np.uint8)
                + ((~p8) & p9).astype(np.uint8)
                + ((~p9) & p2).astype(np.uint8)
            )

            if step == 0:
                cond = (~(p2 & p4 & p6)) & (~(p4 & p6 & p8))
            else:
                cond = (~(p2 & p4 & p8)) & (~(p2 & p6 & p8))

            drop = skel[1:-1, 1:-1] & (b >= 2) & (b <= 6) & (a == 1) & cond
            if drop.any():
                skel[1:-1, 1:-1] &= ~drop
                changed = True

        if not changed:
            break

    return skel[1:-1, 1:-1]


def _line_mask(img_gray: np.ndarray, mode: str = "auto") -> np.ndarray:
    """Return a boolean mask: True where ink lines are."""
    gray = img_gray if img_gray.ndim == 2 else img_gray.mean(axis=2).astype(np.uint8)
    if mode == "auto":
        # Line art is mostly white with thin dark strokes -> few dark pixels.
        dark_frac = float((gray < 128).mean())
        mode = "lineart" if dark_frac < 0.25 else "photo"
    if mode == "photo":
        gray = _xdog(gray)
    bw = _otsu_binary_inv(gray)
    return _morph_close_ellipse_3x3(bw)


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
    """Iterative RDP, safe for detailed paths longer than Python's recursion cap."""
    if len(points) < 3:
        return points

    keep = {0, len(points) - 1}
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        if end - start < 2:
            continue
        ax, ay = points[start]
        bx, by = points[end]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)

        best_index = -1
        best_distance = -1.0
        for index in range(start + 1, end):
            px, py = points[index]
            distance = (
                math.hypot(px - ax, py - ay)
                if length == 0.0
                else abs(dx * (py - ay) - dy * (px - ax)) / length
            )
            if distance > best_distance:
                best_distance = distance
                best_index = index

        if best_distance > eps:
            keep.add(best_index)
            stack.append((start, best_index))
            stack.append((best_index, end))

    return [points[index] for index in sorted(keep)]


def _stroke_len(poly: list) -> float:
    return sum(math.hypot(poly[i + 1][0] - poly[i][0], poly[i + 1][1] - poly[i][1])
               for i in range(len(poly) - 1))


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
def trace(image_bytes: bytes, label: str = "illustration",
          mode: str = "auto", quality: str = "detailed") -> dict[str, Any]:
    """
    Trace `image_bytes` into a raw stroke plan for `_clean_illustration`.

    Returns `{"kind": "strokes", "label", "strokes": [{"role", "points"}]}` with
    points on a 0..1000 canvas, or `{"kind": "refusal", "message"}` when there is
    nothing traceable — the same honest-degradation contract as the model path.
    """
    quality = normalize_quality(quality)
    profile = profile_for(quality)
    if not image_bytes:
        return {"kind": "refusal", "message": "That image could not be read."}

    try:
        with Image.open(io.BytesIO(image_bytes)) as pil_img:
            gray_pil = pil_img.convert("L")
            w, h = gray_pil.size
            if w <= 0 or h <= 0:
                return {"kind": "refusal", "message": "That image could not be read."}
            source_aspect_ratio = w / max(1, h)
            scale = min(1.0, profile.work_max_side / max(h, w))
            if scale < 1.0:
                new_w = max(1, int(w * scale))
                new_h = max(1, int(h * scale))
                gray_pil = gray_pil.resize((new_w, new_h), Image.Resampling.BOX)
                w, h = gray_pil.size
            gray = np.asarray(gray_pil, dtype=np.uint8)
    except Exception:  # noqa: BLE001
        return {"kind": "refusal", "message": "That image could not be read."}

    skel = _skeletonize(_line_mask(gray, mode))
    polys = _skeleton_to_paths(skel)

    strokes: list[dict[str, Any]] = []
    for poly in polys:
        if len(poly) < 2 or _stroke_len(poly) < profile.min_stroke_pixels:
            continue
        simp = _rdp(poly, profile.rdp_epsilon)
        if len(simp) > profile.max_points_per_stroke:
            idx = np.linspace(
                0, len(simp) - 1, profile.max_points_per_stroke
            ).astype(int)
            simp = [simp[i] for i in idx]
        xs = [p[0] for p in simp]
        ys = [p[1] for p in simp]
        diag = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
        strokes.append({"poly": simp, "diag": diag})

    if not strokes:
        return {"kind": "refusal", "message": _DEFAULT_REFUSAL}

    # Order like a hand: biggest silhouettes first, small detail last.
    strokes.sort(key=lambda s: s["diag"], reverse=True)
    strokes = strokes[:profile.max_strokes]
    biggest = strokes[0]["diag"] or 1.0

    out = []
    total_points = 0
    for s in strokes:
        remaining = profile.max_total_points - total_points
        if remaining < 2:
            break
        poly = s["poly"]
        if len(poly) > remaining:
            idx = np.linspace(0, len(poly) - 1, remaining).astype(int)
            poly = [poly[i] for i in idx]
        role = "outline" if s["diag"] >= _OUTLINE_FRACTION * biggest else "detail"
        # 0..1000 canvas — the raw shape _clean_illustration expects as input.
        points = [[round(x / w * 1000, 2), round(y / h * 1000, 2)]
                  for x, y in poly]
        out.append({"role": role, "points": points})
        total_points += len(points)

    return {
        "kind": "strokes",
        "label": (label or "illustration")[:120],
        "quality": quality,
        "aspect_ratio": round(source_aspect_ratio, 4),
        "strokes": out,
    }
