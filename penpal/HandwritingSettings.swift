import Foundation
import Combine
import UIKit

enum HandwritingSizeMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case manual
    var id: String { rawValue }
}

/// One persisted source of truth for layout, rendering and Pencil capture.
@MainActor
final class HandwritingSettings: ObservableObject {
    static let shared = HandwritingSettings()

    @Published var sizeMode: HandwritingSizeMode { didSet { save() } }
    @Published var manualSize: Double { didSet { save() } }
    @Published var penWidthScale: Double { didSet { save() } }
    /// 0 = raw ink (straight segments between captured points), 1 = fully curved.
    @Published var smoothness: Double { didSet { save() } }
    @Published var letterSpacingScale: Double { didSet { save() } }
    @Published var wordSpacingScale: Double { didSet { save() } }
    @Published var lineSpacingScale: Double { didSet { save() } }
    @Published var speedLevel: Double { didSet { save() } }
    @Published var variation: Double { didSet { save() } }
    @Published var pencilOnly: Bool { didSet { save() } }
    /// "indigo" | "blue" | "black" | "green" | "purple" | "custom" | "active".
    @Published var inkColorName: String { didSet { save() } }
    /// The color picked via the full color picker ("custom" swatch), stored as hex.
    @Published var customColorHex: String { didSet { save() } }
    /// Live-tracked color of the user's currently selected pen tool (the system
    /// PKToolPicker tray) — kept in sync by MagicPaperView, never persisted.
    /// Selecting "active" makes replies always match whatever color the user
    /// is writing with right now, instead of a fixed reply color.
    @Published var activeToolColor: UIColor?
    @Published var autoReply: Bool { didSet { save() } }
    @Published var diagnostics: Bool { didSet { save() } }
    /// Paper background: "ruled" | "grid" | "dots" | "blank".
    @Published var paperStyle: String { didSet { save() } }
    /// How replies are written: "hand" (your trained handwriting, pen-drawn)
    /// or "font" (typeset in a chosen font).
    @Published var replyStyle: String { didSet { save() } }
    @Published var replyFontName: String { didSet { save() } }
    /// Django brain base URL, e.g. http://127.0.0.1:8000
    @Published var apiBaseURL: String { didSet { save() } }
    /// When on, typed messages go to Gemini via Django.
    @Published var useBrain: Bool { didSet { save() } }
    /// What Penpal IS right now: "companion" (conversation, moods) or
    /// "mathematician" (step-by-step math solving).
    @Published var capability: String { didSet { save() } }
    /// Companion mood: "warm" | "playful" | "thoughtful" | "coach" | "custom".
    @Published var companionMood: String { didSet { save() } }
    /// Free-text persona used when companionMood == "custom".
    @Published var customMoodText: String { didSet { save() } }
    /// Mathematician default detail: "answer" | "compact" | "full".
    @Published var mathDetail: String { didSet { save() } }
    /// Show the "5 × 5 — Solve" confirmation chip before computing, so a
    /// misread never becomes a wrong answer. Off = solve immediately.
    @Published var confirmBeforeSolving: Bool { didSet { save() } }

    private init(defaults: UserDefaults = .standard) {
        sizeMode = HandwritingSizeMode(rawValue: defaults.string(forKey: "penpal.settings.sizeMode") ?? "") ?? .automatic
        manualSize = defaults.object(forKey: "penpal.settings.size") as? Double ?? 18
        penWidthScale = defaults.object(forKey: "penpal.settings.penScale") as? Double ?? 1
        smoothness = defaults.object(forKey: "penpal.settings.smoothness") as? Double ?? 0.5
        letterSpacingScale = defaults.object(forKey: "penpal.settings.letterSpacing") as? Double ?? 1
        wordSpacingScale = defaults.object(forKey: "penpal.settings.wordSpacing") as? Double ?? 1
        lineSpacingScale = defaults.object(forKey: "penpal.settings.lineSpacing") as? Double ?? 1
        speedLevel = defaults.object(forKey: "penpal.settings.speed") as? Double ?? 5
        variation = defaults.object(forKey: "penpal.settings.variation") as? Double ?? 4
        // PEN-INTERACT — the Pencil draws, the hand operates. The finger is
        // now the way to USE the page (scrolling, and pressing the controls
        // inside a code block), so it can no longer also mean "draw": one
        // input cannot carry both meanings without guessing. V3 key so the
        // old stored preference doesn't reinstate finger drawing.
        pencilOnly = defaults.object(forKey: "penpal.settings.pencilOnlyV3") as? Bool ?? true
        inkColorName = defaults.string(forKey: "penpal.settings.inkColor") ?? "indigo"
        customColorHex = defaults.string(forKey: "penpal.settings.customColorHex") ?? "#3B3B3B"
        autoReply = defaults.object(forKey: "penpal.settings.autoReply") as? Bool ?? true
        diagnostics = defaults.object(forKey: "penpal.settings.detect") as? Bool ?? false
        paperStyle = defaults.string(forKey: "penpal.settings.paperStyle") ?? "blank"
        replyStyle = defaults.string(forKey: "penpal.settings.replyStyle") ?? "hand"
        replyFontName = defaults.string(forKey: "penpal.settings.replyFont") ?? "SnellRoundhand"
        apiBaseURL = defaults.string(forKey: "penpal.settings.apiBaseURL") ?? "http://127.0.0.1:8000"
        useBrain = defaults.object(forKey: "penpal.settings.useBrain") as? Bool ?? true
        capability = defaults.string(forKey: "penpal.settings.capability") ?? "companion"
        companionMood = defaults.string(forKey: "penpal.settings.companionMood") ?? "warm"
        customMoodText = defaults.string(forKey: "penpal.settings.customMoodText") ?? ""
        mathDetail = defaults.string(forKey: "penpal.settings.mathDetail") ?? "compact"
        confirmBeforeSolving = defaults.object(forKey: "penpal.settings.confirmSolve") as? Bool ?? true
    }

    var inkColor: UIColor {
        switch inkColorName {
        case "blue": return .systemBlue
        case "black": return .label
        case "green": return .systemGreen
        case "purple": return .systemPurple
        case "custom": return UIColor(hex: customColorHex) ?? .systemIndigo
        case "active": return activeToolColor ?? .systemIndigo
        default: return .systemIndigo
        }
    }

    func resolvedSize(detected: CGFloat) -> CGFloat {
        sizeMode == .manual ? CGFloat(min(42, max(10, manualSize))) : detected
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(sizeMode.rawValue, forKey: "penpal.settings.sizeMode")
        d.set(manualSize, forKey: "penpal.settings.size")
        d.set(penWidthScale, forKey: "penpal.settings.penScale")
        d.set(smoothness, forKey: "penpal.settings.smoothness")
        d.set(letterSpacingScale, forKey: "penpal.settings.letterSpacing")
        d.set(wordSpacingScale, forKey: "penpal.settings.wordSpacing")
        d.set(lineSpacingScale, forKey: "penpal.settings.lineSpacing")
        d.set(speedLevel, forKey: "penpal.settings.speed")
        d.set(variation, forKey: "penpal.settings.variation")
        d.set(pencilOnly, forKey: "penpal.settings.pencilOnlyV3")
        d.set(inkColorName, forKey: "penpal.settings.inkColor")
        d.set(customColorHex, forKey: "penpal.settings.customColorHex")
        d.set(autoReply, forKey: "penpal.settings.autoReply")
        d.set(diagnostics, forKey: "penpal.settings.detect")
        d.set(paperStyle, forKey: "penpal.settings.paperStyle")
        d.set(replyStyle, forKey: "penpal.settings.replyStyle")
        d.set(replyFontName, forKey: "penpal.settings.replyFont")
        d.set(apiBaseURL, forKey: "penpal.settings.apiBaseURL")
        d.set(useBrain, forKey: "penpal.settings.useBrain")
        d.set(capability, forKey: "penpal.settings.capability")
        d.set(companionMood, forKey: "penpal.settings.companionMood")
        d.set(customMoodText, forKey: "penpal.settings.customMoodText")
        d.set(mathDetail, forKey: "penpal.settings.mathDetail")
        d.set(confirmBeforeSolving, forKey: "penpal.settings.confirmSolve")
    }
}

// MARK: - Hex color bridging (for the custom ink color picker)

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r, g, b, a: UInt64
        if hasAlpha {
            r = (value >> 24) & 0xFF; g = (value >> 16) & 0xFF
            b = (value >> 8) & 0xFF;  a = value & 0xFF
        } else {
            r = (value >> 16) & 0xFF; g = (value >> 8) & 0xFF
            b = value & 0xFF;         a = 0xFF
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// Hex string in the current (resolved) appearance — used to persist a
    /// color picked from SwiftUI's ColorPicker regardless of dark/light mode.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

