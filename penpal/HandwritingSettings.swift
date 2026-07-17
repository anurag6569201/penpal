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
    @Published var inkColorName: String { didSet { save() } }
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
        // Default to allowing finger + Pencil (like Apple Notes). New key so the
        // previous "Pencil only" default doesn't silently block finger drawing.
        pencilOnly = defaults.object(forKey: "penpal.settings.pencilOnlyV2") as? Bool ?? false
        inkColorName = defaults.string(forKey: "penpal.settings.inkColor") ?? "indigo"
        autoReply = defaults.object(forKey: "penpal.settings.autoReply") as? Bool ?? true
        diagnostics = defaults.object(forKey: "penpal.settings.detect") as? Bool ?? false
        paperStyle = defaults.string(forKey: "penpal.settings.paperStyle") ?? "blank"
        replyStyle = defaults.string(forKey: "penpal.settings.replyStyle") ?? "hand"
        replyFontName = defaults.string(forKey: "penpal.settings.replyFont") ?? "SnellRoundhand"
        apiBaseURL = defaults.string(forKey: "penpal.settings.apiBaseURL") ?? "http://127.0.0.1:8000"
        useBrain = defaults.object(forKey: "penpal.settings.useBrain") as? Bool ?? true
    }

    var inkColor: UIColor {
        switch inkColorName {
        case "blue": return .systemBlue
        case "black": return .label
        case "green": return .systemGreen
        case "purple": return .systemPurple
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
        d.set(pencilOnly, forKey: "penpal.settings.pencilOnlyV2")
        d.set(inkColorName, forKey: "penpal.settings.inkColor")
        d.set(autoReply, forKey: "penpal.settings.autoReply")
        d.set(diagnostics, forKey: "penpal.settings.detect")
        d.set(paperStyle, forKey: "penpal.settings.paperStyle")
        d.set(replyStyle, forKey: "penpal.settings.replyStyle")
        d.set(replyFontName, forKey: "penpal.settings.replyFont")
        d.set(apiBaseURL, forKey: "penpal.settings.apiBaseURL")
        d.set(useBrain, forKey: "penpal.settings.useBrain")
    }
}

