//
//  StrokeFont.swift
//  penpal
//
//  A single-stroke "handwriting" font. Each glyph is defined as pen strokes
//  (polylines / elliptical arcs / dots) in a normalized space:
//  baseline y = 0, x-height y = 1, ascender ~1.6, descender ~-0.55, y grows UP.
//  Layout converts glyphs into jittered, slanted ink strokes in view space.
//

import UIKit

/// One continuous pen stroke ready to be drawn/animated in view coordinates.
struct InkStroke {
    var points: [CGPoint]
    var isDot: Bool = false
    var dotRadius: CGFloat = 0
    /// Optional per-point pen widths (pressure). Must match `points.count`.
    var widths: [CGFloat]?
    /// Real writing time for this stroke in seconds (captured tempo). Nil -> synthetic speed.
    var duration: Double?
    /// Real pen-lift pause before this stroke in seconds. Nil -> synthetic pause.
    var pauseBefore: Double?
    /// Captured per-point timing and Pencil dynamics, when this is real ink.
    var pointTimes: [Double]? = nil
    var forces: [CGFloat]? = nil
    var altitudes: [CGFloat]? = nil
    var azimuths: [CGFloat]? = nil
    /// Semantic scheduling metadata.
    var wordIndex: Int = 0
    var letterIndex: Int? = nil
    var isWordStart: Bool = false
    var source: WordInkSource = .letters
    var confidence: CGFloat = 0.35
}

struct WritingSequence {
    var strokes: [InkStroke]
    var bottomY: CGFloat
    var clipped: Bool = false
    var confidence: CGFloat {
        guard !strokes.isEmpty else { return 0 }
        return strokes.map(\.confidence).reduce(0, +) / CGFloat(strokes.count)
    }
}

enum StrokeElement {
    case poly([CGPoint])                                            // control points, catmull-rom smoothed
    case arc(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
             a0: CGFloat, a1: CGFloat)                              // degrees
    case dot(CGFloat, CGFloat)
}

struct Glyph {
    let width: CGFloat
    let strokes: [StrokeElement]
}

enum StrokeFont {

    private static func p(_ v: CGFloat...) -> StrokeElement {
        var pts: [CGPoint] = []
        var i = 0
        while i + 1 < v.count { pts.append(CGPoint(x: v[i], y: v[i + 1])); i += 2 }
        return .poly(pts)
    }

    static let glyphs: [Character: Glyph] = [
        " ": Glyph(width: 0.55, strokes: []),
        "a": Glyph(width: 0.62, strokes: [.arc(cx: 0.28, cy: 0.5, rx: 0.26, ry: 0.48, a0: 50, a1: 395),
                                          p(0.54, 0.95, 0.54, 0.12, 0.62, 0)]),
        "b": Glyph(width: 0.60, strokes: [p(0.07, 1.6, 0.07, 0.02),
                                          .arc(cx: 0.32, cy: 0.5, rx: 0.26, ry: 0.47, a0: 145, a1: -125)]),
        "c": Glyph(width: 0.55, strokes: [.arc(cx: 0.30, cy: 0.5, rx: 0.26, ry: 0.48, a0: 55, a1: 310)]),
        "d": Glyph(width: 0.62, strokes: [.arc(cx: 0.28, cy: 0.5, rx: 0.26, ry: 0.48, a0: 50, a1: 400),
                                          p(0.55, 1.6, 0.55, 0.12, 0.62, 0)]),
        "e": Glyph(width: 0.56, strokes: [p(0.07, 0.52, 0.48, 0.55),
                                          .arc(cx: 0.28, cy: 0.5, rx: 0.25, ry: 0.48, a0: 8, a1: 300)]),
        "f": Glyph(width: 0.50, strokes: [p(0.48, 1.45, 0.38, 1.6, 0.26, 1.55, 0.22, 1.3, 0.22, 0),
                                          p(0.03, 1.0, 0.44, 1.0)]),
        "g": Glyph(width: 0.62, strokes: [.arc(cx: 0.28, cy: 0.5, rx: 0.26, ry: 0.48, a0: 50, a1: 395),
                                          p(0.54, 0.9, 0.54, -0.2, 0.42, -0.52, 0.15, -0.45)]),
        "h": Glyph(width: 0.58, strokes: [p(0.07, 1.6, 0.07, 0),
                                          p(0.07, 0.6, 0.15, 0.9, 0.33, 0.95, 0.48, 0.75, 0.50, 0.5, 0.50, 0)]),
        "i": Glyph(width: 0.22, strokes: [p(0.09, 1.0, 0.09, 0), .dot(0.09, 1.32)]),
        "j": Glyph(width: 0.32, strokes: [p(0.22, 1.0, 0.22, -0.2, 0.12, -0.5, -0.06, -0.42), .dot(0.22, 1.32)]),
        "k": Glyph(width: 0.56, strokes: [p(0.07, 1.6, 0.07, 0),
                                          p(0.50, 0.95, 0.09, 0.45),
                                          p(0.22, 0.58, 0.52, 0)]),
        "l": Glyph(width: 0.26, strokes: [p(0.09, 1.6, 0.09, 0.1, 0.17, 0)]),
        "m": Glyph(width: 0.90, strokes: [p(0.06, 1.0, 0.06, 0),
                                          p(0.06, 0.6, 0.14, 0.9, 0.30, 0.95, 0.42, 0.72, 0.44, 0.5, 0.44, 0),
                                          p(0.44, 0.6, 0.52, 0.9, 0.68, 0.95, 0.80, 0.72, 0.82, 0.5, 0.82, 0)]),
        "n": Glyph(width: 0.58, strokes: [p(0.07, 1.0, 0.07, 0),
                                          p(0.07, 0.6, 0.15, 0.9, 0.33, 0.95, 0.48, 0.75, 0.50, 0.5, 0.50, 0)]),
        "o": Glyph(width: 0.60, strokes: [.arc(cx: 0.30, cy: 0.5, rx: 0.26, ry: 0.48, a0: 90, a1: 450)]),
        "p": Glyph(width: 0.60, strokes: [p(0.07, 1.0, 0.07, -0.55),
                                          .arc(cx: 0.32, cy: 0.5, rx: 0.26, ry: 0.46, a0: 140, a1: -130)]),
        "q": Glyph(width: 0.62, strokes: [.arc(cx: 0.28, cy: 0.5, rx: 0.26, ry: 0.48, a0: 50, a1: 395),
                                          p(0.54, 0.9, 0.54, -0.35, 0.68, -0.5)]),
        "r": Glyph(width: 0.44, strokes: [p(0.07, 1.0, 0.07, 0),
                                          p(0.07, 0.55, 0.16, 0.9, 0.32, 0.97, 0.42, 0.88)]),
        "s": Glyph(width: 0.50, strokes: [p(0.44, 0.85, 0.30, 0.99, 0.13, 0.88, 0.13, 0.65, 0.30, 0.52,
                                            0.42, 0.35, 0.38, 0.08, 0.16, 0.02, 0.04, 0.14)]),
        "t": Glyph(width: 0.50, strokes: [p(0.25, 1.4, 0.25, 0.12, 0.34, 0),
                                          p(0.04, 1.0, 0.47, 1.0)]),
        "u": Glyph(width: 0.60, strokes: [p(0.07, 1.0, 0.07, 0.3, 0.15, 0.03, 0.32, 0.02, 0.46, 0.2, 0.50, 0.4, 0.50, 1.0),
                                          p(0.50, 0.5, 0.50, 0.1, 0.58, 0)]),
        "v": Glyph(width: 0.52, strokes: [p(0.04, 1.0, 0.26, 0, 0.48, 1.0)]),
        "w": Glyph(width: 0.72, strokes: [p(0.02, 1.0, 0.17, 0, 0.34, 0.7, 0.50, 0, 0.66, 1.0)]),
        "x": Glyph(width: 0.54, strokes: [p(0.05, 1.0, 0.50, 0), p(0.50, 1.0, 0.05, 0)]),
        "y": Glyph(width: 0.56, strokes: [p(0.05, 1.0, 0.28, 0.2),
                                          p(0.52, 1.0, 0.20, -0.45, 0.02, -0.48)]),
        "z": Glyph(width: 0.54, strokes: [p(0.05, 1.0, 0.48, 1.0, 0.06, 0.02, 0.50, 0.02)]),

        "A": Glyph(width: 0.66, strokes: [p(0.04, 0, 0.32, 1.6, 0.60, 0), p(0.15, 0.55, 0.50, 0.55)]),
        "B": Glyph(width: 0.60, strokes: [p(0.07, 1.6, 0.07, 0),
                                          p(0.07, 1.6, 0.40, 1.55, 0.46, 1.25, 0.40, 0.95, 0.07, 0.85),
                                          p(0.07, 0.85, 0.45, 0.78, 0.52, 0.40, 0.44, 0.06, 0.07, 0)]),
        "C": Glyph(width: 0.66, strokes: [.arc(cx: 0.36, cy: 0.8, rx: 0.30, ry: 0.80, a0: 55, a1: 305)]),
        "D": Glyph(width: 0.64, strokes: [p(0.07, 1.6, 0.07, 0),
                                          p(0.07, 1.6, 0.35, 1.55, 0.55, 1.15, 0.57, 0.8, 0.53, 0.4, 0.33, 0.04, 0.07, 0)]),
        "E": Glyph(width: 0.56, strokes: [p(0.50, 1.6, 0.07, 1.6, 0.07, 0, 0.50, 0), p(0.07, 0.82, 0.40, 0.82)]),
        "G": Glyph(width: 0.68, strokes: [.arc(cx: 0.36, cy: 0.8, rx: 0.30, ry: 0.80, a0: 55, a1: 330),
                                          p(0.64, 0.40, 0.62, 0.58, 0.40, 0.58)]),
        "H": Glyph(width: 0.66, strokes: [p(0.07, 1.6, 0.07, 0), p(0.58, 1.6, 0.58, 0), p(0.07, 0.8, 0.58, 0.8)]),
        "I": Glyph(width: 0.24, strokes: [p(0.11, 1.6, 0.11, 0)]),
        "J": Glyph(width: 0.44, strokes: [p(0.36, 1.6, 0.36, 0.2, 0.24, 0.0, 0.08, 0.08)]),
        "K": Glyph(width: 0.62, strokes: [p(0.07, 1.6, 0.07, 0), p(0.56, 1.6, 0.09, 0.7), p(0.26, 0.9, 0.58, 0)]),
        "L": Glyph(width: 0.52, strokes: [p(0.07, 1.6, 0.07, 0, 0.48, 0)]),
        "M": Glyph(width: 0.80, strokes: [p(0.05, 0, 0.06, 1.6, 0.40, 0.35, 0.72, 1.6, 0.73, 0)]),
        "N": Glyph(width: 0.66, strokes: [p(0.06, 0, 0.06, 1.6, 0.58, 0.02, 0.58, 1.6)]),
        "O": Glyph(width: 0.70, strokes: [.arc(cx: 0.35, cy: 0.8, rx: 0.30, ry: 0.80, a0: 90, a1: 450)]),
        "P": Glyph(width: 0.58, strokes: [p(0.07, 1.6, 0.07, 0),
                                          p(0.07, 1.55, 0.42, 1.5, 0.50, 1.2, 0.42, 0.9, 0.07, 0.82)]),
        "R": Glyph(width: 0.60, strokes: [p(0.07, 1.6, 0.07, 0),
                                          p(0.07, 1.55, 0.42, 1.5, 0.50, 1.2, 0.42, 0.9, 0.07, 0.82),
                                          p(0.24, 0.82, 0.54, 0)]),
        "S": Glyph(width: 0.56, strokes: [p(0.48, 1.35, 0.32, 1.58, 0.12, 1.42, 0.12, 1.05, 0.32, 0.85,
                                            0.46, 0.60, 0.42, 0.14, 0.16, 0.02, 0.02, 0.20)]),
        "T": Glyph(width: 0.60, strokes: [p(0.02, 1.6, 0.58, 1.6), p(0.30, 1.6, 0.30, 0)]),
        "U": Glyph(width: 0.64, strokes: [p(0.07, 1.6, 0.07, 0.35, 0.18, 0.03, 0.40, 0.02, 0.55, 0.25, 0.57, 0.5, 0.57, 1.6)]),
        "V": Glyph(width: 0.62, strokes: [p(0.04, 1.6, 0.31, 0, 0.58, 1.6)]),
        "W": Glyph(width: 0.86, strokes: [p(0.02, 1.6, 0.20, 0, 0.40, 1.1, 0.60, 0, 0.78, 1.6)]),
        "Y": Glyph(width: 0.60, strokes: [p(0.04, 1.6, 0.30, 0.72), p(0.56, 1.6, 0.30, 0.72, 0.30, 0)]),

        ".": Glyph(width: 0.26, strokes: [.dot(0.10, 0.05)]),
        ",": Glyph(width: 0.26, strokes: [p(0.12, 0.12, 0.04, -0.22)]),
        "!": Glyph(width: 0.24, strokes: [p(0.10, 1.6, 0.10, 0.45), .dot(0.10, 0.05)]),
        "?": Glyph(width: 0.50, strokes: [p(0.05, 1.25, 0.14, 1.5, 0.30, 1.58, 0.44, 1.42, 0.44, 1.12, 0.27, 0.85, 0.26, 0.5),
                                          .dot(0.26, 0.05)]),
        "'": Glyph(width: 0.16, strokes: [p(0.08, 1.5, 0.03, 1.28)]),
        "\"": Glyph(width: 0.30, strokes: [p(0.08, 1.5, 0.04, 1.25), p(0.23, 1.5, 0.18, 1.25)]),
        ":": Glyph(width: 0.24, strokes: [.dot(0.10, 0.82), .dot(0.10, 0.08)]),
        ";": Glyph(width: 0.26, strokes: [.dot(0.12, 0.82), p(0.12, 0.15, 0.04, -0.18)]),
        "-": Glyph(width: 0.42, strokes: [p(0.04, 0.52, 0.38, 0.52)]),
        "(": Glyph(width: 0.30, strokes: [.arc(cx: 0.28, cy: 0.65, rx: 0.22, ry: 0.90, a0: 105, a1: 255)]),
        ")": Glyph(width: 0.30, strokes: [.arc(cx: 0.02, cy: 0.65, rx: 0.22, ry: 0.90, a0: -75, a1: 75)]),
        "0": Glyph(width: 0.62, strokes: [.arc(cx: 0.31, cy: 0.78, rx: 0.27, ry: 0.76, a0: 90, a1: 450)]),
        "1": Glyph(width: 0.38, strokes: [p(0.06, 1.30, 0.20, 1.55, 0.20, 0.02), p(0.06, 0.02, 0.34, 0.02)]),
        "2": Glyph(width: 0.58, strokes: [p(0.05, 1.28, 0.18, 1.52, 0.40, 1.50, 0.52, 1.30, 0.46, 1.06, 0.05, 0.02, 0.54, 0.02)]),
        "3": Glyph(width: 0.56, strokes: [p(0.04, 1.42, 0.28, 1.55, 0.50, 1.36, 0.27, 0.82, 0.49, 0.66, 0.50, 0.22, 0.26, 0.01, 0.03, 0.16)]),
        "4": Glyph(width: 0.60, strokes: [p(0.44, 0, 0.44, 1.55, 0.04, 0.48, 0.57, 0.48)]),
        "5": Glyph(width: 0.56, strokes: [p(0.49, 1.52, 0.10, 1.52, 0.07, 0.86, 0.36, 0.88, 0.51, 0.66, 0.48, 0.20, 0.24, 0.01, 0.03, 0.16)]),
        "6": Glyph(width: 0.58, strokes: [p(0.48, 1.39, 0.28, 1.54, 0.09, 1.27, 0.05, 0.55, 0.18, 0.06, 0.42, 0.04, 0.53, 0.34, 0.43, 0.70, 0.13, 0.67)]),
        "7": Glyph(width: 0.54, strokes: [p(0.03, 1.52, 0.51, 1.52, 0.18, 0.02)]),
        "8": Glyph(width: 0.58, strokes: [.arc(cx: 0.29, cy: 1.17, rx: 0.23, ry: 0.38, a0: 90, a1: 450),
                                          .arc(cx: 0.29, cy: 0.38, rx: 0.25, ry: 0.39, a0: 90, a1: 450)]),
        "9": Glyph(width: 0.58, strokes: [p(0.48, 0.18, 0.49, 1.00, 0.39, 1.50, 0.15, 1.52, 0.04, 1.20, 0.14, 0.86, 0.44, 0.88)]),

        // Math symbols — Mathematician mode writes equations; without these
        // every "=" or "+" fell back to the "?" glyph.
        "=": Glyph(width: 0.54, strokes: [p(0.05, 0.70, 0.49, 0.70), p(0.05, 0.40, 0.49, 0.40)]),
        "+": Glyph(width: 0.54, strokes: [p(0.05, 0.55, 0.49, 0.55), p(0.27, 0.80, 0.27, 0.30)]),
        "*": Glyph(width: 0.44, strokes: [p(0.22, 0.85, 0.22, 0.45), p(0.05, 0.75, 0.39, 0.55), p(0.05, 0.55, 0.39, 0.75)]),
        "/": Glyph(width: 0.46, strokes: [p(0.42, 1.35, 0.04, 0.02)]),
        "^": Glyph(width: 0.44, strokes: [p(0.05, 1.10, 0.22, 1.45, 0.39, 1.10)]),
        "<": Glyph(width: 0.50, strokes: [p(0.45, 0.90, 0.05, 0.55, 0.45, 0.20)]),
        ">": Glyph(width: 0.50, strokes: [p(0.05, 0.90, 0.45, 0.55, 0.05, 0.20)]),
        "%": Glyph(width: 0.62, strokes: [p(0.50, 1.30, 0.10, 0.10),
                                          .arc(cx: 0.14, cy: 1.18, rx: 0.11, ry: 0.16, a0: 0, a1: 360),
                                          .arc(cx: 0.46, cy: 0.24, rx: 0.11, ry: 0.16, a0: 0, a1: 360)]),
        "×": Glyph(width: 0.46, strokes: [p(0.06, 0.85, 0.40, 0.25), p(0.40, 0.85, 0.06, 0.25)]),
        "÷": Glyph(width: 0.54, strokes: [p(0.05, 0.55, 0.49, 0.55), .dot(0.27, 0.88), .dot(0.27, 0.22)]),
        "π": Glyph(width: 0.60, strokes: [p(0.03, 1.02, 0.57, 1.02), p(0.16, 1.02, 0.14, 0.02), p(0.44, 1.02, 0.46, 0.02)]),

        // Extended math symbols — the brain writes √, ≤, ∫ … directly now;
        // without these each one fell back to the "?" glyph.
        "√": Glyph(width: 0.72, strokes: [p(0.02, 0.60, 0.14, 0.66, 0.26, 0.04, 0.42, 1.48, 0.70, 1.48)]),
        "≤": Glyph(width: 0.52, strokes: [p(0.45, 1.00, 0.05, 0.65, 0.45, 0.34), p(0.05, 0.12, 0.45, 0.12)]),
        "≥": Glyph(width: 0.52, strokes: [p(0.05, 1.00, 0.45, 0.65, 0.05, 0.34), p(0.05, 0.12, 0.45, 0.12)]),
        "≠": Glyph(width: 0.54, strokes: [p(0.05, 0.70, 0.49, 0.70), p(0.05, 0.40, 0.49, 0.40), p(0.40, 0.95, 0.14, 0.15)]),
        "±": Glyph(width: 0.54, strokes: [p(0.05, 0.62, 0.49, 0.62), p(0.27, 0.88, 0.27, 0.38), p(0.05, 0.12, 0.49, 0.12)]),
        "≈": Glyph(width: 0.56, strokes: [p(0.04, 0.66, 0.14, 0.76, 0.27, 0.66, 0.40, 0.56, 0.50, 0.66),
                                          p(0.04, 0.38, 0.14, 0.48, 0.27, 0.38, 0.40, 0.28, 0.50, 0.38)]),
        "∫": Glyph(width: 0.48, strokes: [p(0.42, 1.42, 0.36, 1.55, 0.27, 1.48, 0.24, 0.75, 0.21, 0.05, 0.12, -0.02, 0.05, 0.10)]),
        "°": Glyph(width: 0.32, strokes: [.arc(cx: 0.15, cy: 1.32, rx: 0.10, ry: 0.13, a0: 0, a1: 360)]),
        "θ": Glyph(width: 0.58, strokes: [.arc(cx: 0.28, cy: 0.78, rx: 0.24, ry: 0.76, a0: 90, a1: 450),
                                          p(0.08, 0.78, 0.48, 0.78)]),
        "∞": Glyph(width: 0.72, strokes: [.arc(cx: 0.20, cy: 0.55, rx: 0.16, ry: 0.24, a0: 30, a1: 390),
                                          .arc(cx: 0.52, cy: 0.55, rx: 0.16, ry: 0.24, a0: 210, a1: 570)]),
        "Δ": Glyph(width: 0.64, strokes: [p(0.32, 1.50, 0.04, 0.02, 0.60, 0.02, 0.32, 1.50)]),
        "·": Glyph(width: 0.24, strokes: [.dot(0.11, 0.55)]),
    ]

    static func glyph(for ch: Character) -> Glyph {
        if let g = glyphs[ch] { return g }
        if let lower = ch.lowercased().first, let g = glyphs[lower] { return g }
        return glyphs["?"]!
    }

    static let letterSpacing: CGFloat = 0.16

    static func advance(_ ch: Character, size: CGFloat) -> CGFloat {
        (glyph(for: ch).width + letterSpacing) * size
    }

    static func wordWidth(_ word: Substring, size: CGFloat) -> CGFloat {
        word.reduce(0) { $0 + advance($1, size: size) }
    }

    // MARK: - Smoothing

    static func catmullRom(_ pts: [CGPoint], samplesPerSegment: Int = 6) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]
            for j in 0..<samplesPerSegment {
                let t = CGFloat(j) / CGFloat(samplesPerSegment)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t
                        + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                        + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t
                        + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                        + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                out.append(CGPoint(x: x, y: y))
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    // MARK: - Glyph -> ink strokes

    /// Produces jittered ink strokes for one character at pen position (originX, baselineY).
    /// Returns strokes plus the x-advance for the pen.
    static func inkStrokes(for ch: Character,
                           originX: CGFloat,
                           baselineY: CGFloat,
                           size: CGFloat,
                           messiness: CGFloat) -> (strokes: [InkStroke], advance: CGFloat) {
        let g = glyph(for: ch)
        let slant: CGFloat = 0.12 + (CGFloat.random(in: -0.5...0.5)) * 0.05 * messiness
        let wobble = CGFloat.random(in: -0.8...0.8) * 1.6 * messiness
        let sz = size * (1 + CGFloat.random(in: -0.5...0.5) * 0.06 * messiness)
        var result: [InkStroke] = []

        func toView(_ u: CGPoint) -> CGPoint {
            let jx = CGFloat.random(in: -0.5...0.5) * size * 0.03 * messiness
            let jy = CGFloat.random(in: -0.5...0.5) * size * 0.03 * messiness
            return CGPoint(x: originX + u.x * sz + u.y * sz * slant + jx + wobble * 0.2,
                           y: baselineY - u.y * sz + jy + wobble * 0.4)
        }

        for element in g.strokes {
            switch element {
            case .poly(let ctrl):
                let smooth = ctrl.count > 2 ? catmullRom(ctrl) : ctrl
                result.append(InkStroke(points: smooth.map(toView)))
            case .arc(let cx, let cy, let rx, let ry, let a0, let a1):
                let n = max(10, Int(abs(a1 - a0) / 12))
                var pts: [CGPoint] = []
                for i in 0...n {
                    let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)) * .pi / 180
                    pts.append(CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a)))
                }
                result.append(InkStroke(points: pts.map(toView)))
            case .dot(let x, let y):
                let c = toView(CGPoint(x: x, y: y))
                result.append(InkStroke(points: [c], isDot: true, dotRadius: max(1.4, size * 0.07)))
            }
        }
        return (result, (g.width + letterSpacing) * sz)
    }

    // MARK: - Text layout

    /// Lays out a full text block with word wrapping. `lineGap` should be the ruled-line gap;
    /// new lines snap to multiples of it. Returns the strokes and the bottom y of the block.
    /// With `useUserHand`, trained personal glyphs are preferred; untrained characters
    /// fall back to the built-in stroke font.
    @MainActor
    static func layout(text: String,
                       origin: CGPoint,
                       xHeight: CGFloat,
                       maxX: CGFloat,
                       lineGap: CGFloat,
                       maxY: CGFloat,
                       messiness: CGFloat,
                       useUserHand: Bool = false) -> (strokes: [InkStroke], bottomY: CGFloat) {
        let sequence = layoutSequence(text: text, origin: origin, xHeight: xHeight,
                                      maxX: maxX, lineGap: lineGap, maxY: maxY,
                                      messiness: messiness, useUserHand: useUserHand,
                                      settings: .shared)
        return (sequence.strokes, sequence.bottomY)
    }

    @MainActor
    static func layoutSequence(text: String,
                               origin: CGPoint,
                               xHeight: CGFloat,
                               maxX: CGFloat,
                               lineGap: CGFloat,
                               maxY: CGFloat,
                               messiness: CGFloat,
                               useUserHand: Bool = false,
                               settings: HandwritingSettings) -> WritingSequence {

        let store = PersonalFontStore.shared
        let style = StyleRL.shared.active
        let effectiveMess = messiness * (useUserHand ? style.messinessScale : 1)
        let userLetterSpacing = CGFloat(settings.letterSpacingScale)
        let punctuation: Set<Character> = [".", ",", "!", "?", "'", "\""]

        func charAdvance(_ ch: Character) -> CGFloat {
            if useUserHand, let a = store.advance(ch, size: xHeight) { return a * userLetterSpacing }
            return advance(ch, size: xHeight) * userLetterSpacing
        }

        func trailingPunctuationCount(_ token: Substring) -> Int {
            var count = 0
            for ch in token.reversed() {
                if punctuation.contains(ch) { count += 1 } else { break }
            }
            return count
        }

        func charsWidth<S: Sequence>(_ chars: S) -> CGFloat where S.Element == Character {
            var total: CGFloat = 0
            for ch in chars { total += charAdvance(ch) }
            return total
        }

        // LINE TRUST: no per-word "evenness" rescale. Captures are line-true —
        // the size the user wrote against the training guides is the size that
        // renders. Pulling words toward a line median resized their writing.

        func tokenWidth(_ token: Substring) -> CGFloat {
            if useUserHand, let a = store.wordAdvance(String(token), size: xHeight) {
                return a * userLetterSpacing
            }
            let trailing = trailingPunctuationCount(token)
            let core = token.dropLast(trailing)
            if useUserHand, trailing > 0, let a = store.wordAdvance(String(core), size: xHeight) {
                return a * userLetterSpacing + charsWidth(token.suffix(trailing))
            }
            return charsWidth(token)
        }

        var strokes: [InkStroke] = []
        var penX = origin.x
        var baseY = origin.y
        // The hand naturally drifts up and down as it crosses the page.
        // Mean-reverting (Ornstein–Uhlenbeck) processes read as human:
        // slow wander that keeps returning to the ruled line, never a
        // runaway walk. Size breathes the same way (±3%) — nobody writes
        // every word at exactly the same height.
        var drift: CGFloat = 0
        var sizeDrift: CGFloat = 0
        let lineAdvance = lineGap * max(1, ceil(xHeight * 2.4
            * CGFloat(settings.lineSpacingScale) / lineGap))
        let profile = store.profile
        let spaceAdvance = (useUserHand
            ? max(0.3, profile.wordGapUnits) * xHeight
            : advance(" ", size: xHeight)) * (useUserHand ? style.spacingScale : 1)
            * CGFloat(settings.wordSpacingScale)

        // Connection state within the current word (cursive joins).
        var lastExit: CGPoint?
        var lastExitTail: [CGPoint] = []
        var lastExitWidth: CGFloat = 0
        var lastEmitted: Character?
        var lastLetterPoints: [CGPoint] = []
        var wordIndex = 0
        var letterIndex = 0

        func emitChar(_ ch: Character, at y: CGFloat, size: CGFloat) {
            // Optical pair kerning: even out the visual ink gap.
            if let prev = lastEmitted {
                penX += OpticalKern.kern(prev, ch) * size * userLetterSpacing
            }
            if useUserHand,
               let r = store.inkStrokes(for: ch, originX: penX, baselineY: y,
                                        size: size, messiness: effectiveMess) {
                var s = r.strokes

                // LigatureEngine decides the join: the user's measured
                // per-pair habits (does THIS hand connect "th"?), hard rules
                // (no joins to/from caps or punctuation), and a collision
                // guard. StyleRL joinBias still nudges the overall appetite.
                if let prevCh = lastEmitted,
                   let exit = lastExit,
                   LigatureEngine.shared.shouldJoin(
                       from: prevCh, to: ch,
                       connectedness: profile.connectedness + style.joinBias),
                   let entryIdx = s.firstIndex(where: { !$0.isDot && $0.points.count > 1 }),
                   s[entryIdx].points.first != nil {
                    let cw = max(1.1, (lastExitWidth > 0 ? lastExitWidth : size * 0.11) * 0.75)
                    let obstacles = lastLetterPoints + s.flatMap { $0.points }
                    let tail = lastExitTail.isEmpty ? [exit] : lastExitTail
                    let head = Array(s[entryIdx].points.prefix(5))
                    if let connector = LigatureEngine.shared.joiner(
                            fromTail: tail, toHead: head, pair: (prevCh, ch),
                            size: size, baselineY: y, inkWidth: cw,
                            obstacles: obstacles) {
                        strokes.append(connector)
                        s[entryIdx].pauseBefore = 0
                    }
                }

                for i in s.indices {
                    s[i].wordIndex = wordIndex
                    s[i].letterIndex = letterIndex
                    s[i].isWordStart = letterIndex == 0 && i == s.startIndex
                }
                strokes.append(contentsOf: s)
                penX += r.advance * userLetterSpacing
                lastLetterPoints = s.flatMap { $0.points }
                if let tail = s.last(where: { !$0.isDot && $0.points.count > 1 }) {
                    lastExit = tail.points.last
                    lastExitTail = Array(tail.points.suffix(5))
                    lastExitWidth = tail.widths?.last ?? 0
                } else {
                    lastExit = nil
                    lastExitTail = []
                }
            } else {
                let (s, adv) = inkStrokes(for: ch, originX: penX, baselineY: y,
                                          size: size, messiness: effectiveMess)
                var tagged = s
                for i in tagged.indices {
                    tagged[i].wordIndex = wordIndex
                    tagged[i].letterIndex = letterIndex
                    tagged[i].isWordStart = letterIndex == 0 && i == tagged.startIndex
                    tagged[i].source = .letters
                    tagged[i].confidence = useUserHand ? 0.6 : 0.2
                }
                strokes.append(contentsOf: tagged)
                penX += adv * userLetterSpacing
                lastExit = nil
                lastExitTail = []
                lastLetterPoints = []
            }
            lastEmitted = ch
            letterIndex += 1
        }

        var clipped = false
        // Explicit newlines force a line break — math replies use one step
        // per line ("3x = 12\nx = 4\nAns: x = 4"), so line structure is
        // meaning, not just wrapping.
        var tokens: [Substring] = []
        let lineBreakToken: Substring = "\n"
        for (li, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if li > 0 { tokens.append(lineBreakToken) }
            tokens.append(contentsOf: line.split(separator: " ", omittingEmptySubsequences: false))
        }
        for token in tokens {
            if token == lineBreakToken {
                penX = origin.x
                baseY += lineAdvance
                drift *= 0.4
                lastExit = nil
                lastExitTail = []
                lastEmitted = nil
                lastLetterPoints = []
                if baseY > maxY { clipped = true; break }
                continue
            }
            let w = tokenWidth(token)
            if penX + w > maxX, penX > origin.x {
                penX = origin.x
                baseY += lineAdvance
                drift *= 0.4
            }
            if baseY > maxY { clipped = true; break }

            // Gentle per-WORD drift only (not per letter). Keeps life without
            // the "ransom note baseline" look from uneven letter samples.
            let driftAmp = effectiveMess * style.driftScale
            drift = drift * 0.86
                + CGFloat.random(in: -1...1) * driftAmp * xHeight * 0.035
            drift = min(max(drift, -xHeight * 0.07 * style.driftScale),
                        xHeight * 0.07 * style.driftScale)
            sizeDrift = sizeDrift * 0.88 + CGFloat.random(in: -1...1) * 0.012
            sizeDrift = min(0.03, max(-0.03, sizeDrift))
            let wordSize = xHeight * (1 + sizeDrift * min(1, effectiveMess + 0.4))
            let y = baseY + drift
            lastExit = nil
            lastExitTail = []
            lastEmitted = nil
            lastLetterPoints = []
            letterIndex = 0

            var handled = false
            if useUserHand {
                if let (s, adv) = store.inkStrokes(forWord: String(token), originX: penX,
                                                   baselineY: y, size: wordSize,
                                                   messiness: effectiveMess) {
                    var tagged = s
                    for i in tagged.indices {
                        tagged[i].wordIndex = wordIndex
                        tagged[i].isWordStart = i == tagged.startIndex
                    }
                    strokes.append(contentsOf: tagged)
                    penX += adv * userLetterSpacing
                    handled = true
                } else {
                    let trailing = trailingPunctuationCount(token)
                    let core = token.dropLast(trailing)
                    if trailing > 0,
                       let (s, adv) = store.inkStrokes(forWord: String(core), originX: penX,
                                                       baselineY: y, size: wordSize,
                                                       messiness: effectiveMess) {
                        var tagged = s
                        for i in tagged.indices {
                            tagged[i].wordIndex = wordIndex
                            tagged[i].isWordStart = i == tagged.startIndex
                        }
                        strokes.append(contentsOf: tagged)
                        penX += adv * userLetterSpacing
                        for ch in token.suffix(trailing) { emitChar(ch, at: y, size: wordSize) }
                        handled = true
                    }
                }
            }
            if !handled {
                for ch in token { emitChar(ch, at: y, size: wordSize) }
            }
            penX += spaceAdvance
            wordIndex += 1
        }
        return WritingSequence(strokes: strokes, bottomY: baseY + xHeight * 0.7,
                               clipped: clipped)
    }
}
