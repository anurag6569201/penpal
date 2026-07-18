//
//  MathGlyphMatcher.swift
//  penpal
//
//  Maps handwritten math stroke clusters to ASCII by comparing them against
//  the user's trained digit/operator samples (Teach it your hand → Math).
//  Used by MathInkParser instead of a cloud vision call for calculator reads.
//

import UIKit
import PencilKit

enum MathGlyphMatcher {

    /// Characters we try to match for calculator recognition.
    static var alphabet: [Character] { CalibrationView.mathChars }

    /// Convert a matched training character into calculator ASCII.
    static func ascii(for ch: Character) -> String {
        switch ch {
        case "×", "·", "∗": return "*"
        case "÷": return "/"
        case "√": return "sqrt"
        case "−", "–", "—": return "-"
        case "²": return "^2"
        case "³": return "^3"
        default: return String(ch)
        }
    }

    /// True when the ASCII token is part of a numeric run (digits / decimal).
    static func isNumericToken(_ ascii: String) -> Bool {
        !ascii.isEmpty && ascii.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Match one stroke cluster to a trained math symbol, if confident.
    static func matchSymbol(strokes: [PKStroke], unit: CGFloat) -> Character? {
        guard PersonalFontStore.shared.hasTrained(anyOf: alphabet) else { return nil }
        return PersonalFontStore.shared
            .matchChar(from: strokes, among: alphabet, unit: unit)?.char
    }

    /// Match each group; returns concatenated ASCII when every group matches
    /// a numeric token. Nil if any group fails (caller falls back to Vision).
    static func matchDigitRun(groups: [[Int]], in strokes: [PKStroke],
                              unit: CGFloat) -> String? {
        guard !groups.isEmpty,
              PersonalFontStore.shared.hasTrained(anyOf: alphabet) else { return nil }
        var out = ""
        for group in groups {
            let cluster = group.map { strokes[$0] }
            guard let ch = matchSymbol(strokes: cluster, unit: unit) else { return nil }
            let token = ascii(for: ch)
            guard isNumericToken(token) else { return nil }
            out += token
        }
        return out.isEmpty ? nil : out
    }
}
