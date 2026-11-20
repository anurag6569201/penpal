//
//  PenpalControlBar.swift
//  penpal
//
//  Persistent, in-context controls for who Penpal is and how it replies.
//

import SwiftUI

enum PenpalControlOptions {
    static let capabilities: [(tag: String, title: String, icon: String)] = [
        ("companion", "Companion", "heart.text.square"),
        ("mathematician", "Mathematician", "x.squareroot"),
        ("interactive", "Interactive", "cursorarrow.click.2"),
        ("illustrator", "Illustrator", "pencil.and.outline"),
        ("language", "Language Partner", "character.bubble"),
        ("debate", "Debate Partner", "arrow.left.arrow.right"),
        // PEN-40 — composes a whole page from several of the above at once.
        ("arranger", "Arranger", "square.grid.2x2"),
    ]

    static let moods: [(tag: String, title: String, icon: String)] = [
        ("warm", "Warm friend", "cup.and.saucer"),
        ("playful", "Playful", "party.popper"),
        ("thoughtful", "Thoughtful", "moon.stars"),
        ("coach", "Coach", "figure.run"),
        ("custom", "Custom…", "wand.and.stars"),
    ]

    static let mathDetails: [(tag: String, title: String, icon: String)] = [
        ("answer", "Answer only", "equal"),
        ("compact", "Compact steps", "list.bullet"),
        ("full", "Full working", "list.number"),
        ("proof", "Proof", "checkmark.seal"),
    ]

    static let illustratorQualities: [(tag: String, title: String, icon: String)] = [
        ("quick", "Quick", "bolt"),
        ("balanced", "Balanced", "slider.horizontal.3"),
        ("detailed", "Detailed (slower)", "sparkles"),
    ]

    static let languages: [(tag: String, title: String)] = [
        ("en-US", "English"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese"),
    ]
}

struct PenpalControlBar: View {
    @ObservedObject var settings: HandwritingSettings
    var activityPhase: InkThinkingIndicator.Phase?
    var statusText: String?
    var rulerActive: Bool = false
    var onAsk: () -> Void
    var onCheckWork: () -> Void = {}
    var onSolveWholePage: () -> Void = {}
    var onPlotGraph: () -> Void = {}
    var onToggleRuler: () -> Void = {}
    var onVisionCamera: () -> Void
    var onVisionPhoto: () -> Void
    var onClose: () -> Void

    @State private var showCustomMoodEditor = false
    @State private var customMoodDraft = ""

    private var isMathematician: Bool {
        settings.capability == "mathematician"
    }

    private var isLanguagePartner: Bool {
        settings.capability == "language"
    }

    private var isIllustrator: Bool {
        settings.capability == "illustrator"
    }

    private var selectedCapability: (tag: String, title: String, icon: String) {
        PenpalControlOptions.capabilities.first { $0.tag == settings.capability }
            ?? PenpalControlOptions.capabilities[0]
    }

    private var hasSecondaryControls: Bool {
        ["companion", "mathematician", "illustrator", "language"]
            .contains(settings.capability)
    }

    private var selectedMoodTitle: String {
        PenpalControlOptions.moods.first { $0.tag == settings.companionMood }?.title
            ?? "Mood"
    }

    private var selectedDetailTitle: String {
        PenpalControlOptions.mathDetails.first { $0.tag == settings.mathDetail }?.title
            ?? "Detail"
    }

    private var selectedLanguageTitle: String {
        PenpalControlOptions.languages.first { $0.tag == settings.targetLanguage }?.title
            ?? "Language"
    }

    private var selectedIllustratorQualityTitle: String {
        PenpalControlOptions.illustratorQualities.first {
            $0.tag == settings.illustratorQuality
        }?.title ?? "Detailed (slower)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if activityPhase != nil || statusText != nil {
                statusSection
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Pen.paperRaised, in: Capsule())
            }
            ViewThatFits(in: .horizontal) {
                dockControls
                ScrollView(.horizontal, showsIndicators: false) { dockControls }
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .background(Pen.paperRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Pen.hairline, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        }
        .font(.subheadline.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .alert("Custom Companion Mood", isPresented: $showCustomMoodEditor) {
            TextField("Describe Penpal's personality", text: $customMoodDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let mood = customMoodDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.customMoodText = mood
                settings.companionMood = "custom"
            }
            .disabled(customMoodDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Keep it short and vivid.")
        }
    }

    private var dockControls: some View {
        HStack(spacing: 6) {
            capabilityMenu
                .tourAnchor(.capability)

            if hasSecondaryControls {
                Divider().frame(height: 20)
                Group {
                    if isMathematician {
                        detailMenu
                    } else if isIllustrator {
                        illustratorQualityMenu
                    } else if isLanguagePartner {
                        languageMenu
                    } else {
                        moodMenu
                    }
                }
                .tourAnchor(.secondary)
            }

            Button {
                TourEventBus.shared.emit(.askTapped)
                onAsk()
            } label: {
                Label(isMathematician ? "Solve" : "Ask Penpal", systemImage: "sparkle")
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .foregroundStyle(Pen.onAccent)
                    .background(Pen.inkAccent, in: Capsule())
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(activityPhase != nil)
            .accessibilityLabel(isMathematician ? "Solve with Penpal" : "Ask Penpal")
            .accessibilityHint("Sends the new handwriting. You can also draw a box around a question.")
            .tourAnchor(.ask)

            if isMathematician {
                Button(action: onCheckWork) {
                    Label("Check", systemImage: "checkmark.circle")
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .foregroundStyle(Pen.inkPrimary)
                        .background(Pen.accentWash, in: Capsule())
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(activityPhase != nil)
                .accessibilityLabel("Check My Working")
                .accessibilityHint("Checks your handwritten math steps for the first mistake")

                mathQuickToolsMenu
            }

            Menu {
                Button("Take Photo", systemImage: "camera") {
                    onVisionCamera()
                }
                Button("Choose Photo", systemImage: "photo.on.rectangle") {
                    onVisionPhoto()
                }
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.body)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Pen.inkPrimary)
            .tourAnchor(.camera)
            .accessibilityLabel(
                settings.capability == "illustrator"
                    ? "Trace a photo"
                    : "Ask Penpal about a photo"
            )
            .accessibilityHint(
                settings.capability == "illustrator"
                    ? "Take or choose a photo to trace as ink"
                    : "Take or choose an external photo"
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Pen.inkFaded)
            .accessibilityLabel("Turn off Penpal mode")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 6) {
            if let activityPhase {
                InkThinkingIndicator(phase: activityPhase)
            }
            if let statusText {
                Text(statusText)
                    .foregroundStyle(Pen.inkFaded)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Penpal status")
        .accessibilityValue(statusText ?? "Working")
    }

    private var capabilityMenu: some View {
        Menu {
            ForEach(PenpalControlOptions.capabilities, id: \.tag) { capability in
                Button {
                    settings.capability = capability.tag
                } label: {
                    Label(capability.title, systemImage:
                            settings.capability == capability.tag
                          ? "checkmark" : capability.icon)
                }
            }
        } label: {
            Label(selectedCapability.title, systemImage: selectedCapability.icon)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .foregroundStyle(Pen.inkAccent)
                .background(Pen.accentWash, in: Capsule())
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Penpal capability, \(selectedCapability.title)")
    }

    private var moodMenu: some View {
        Menu {
            ForEach(PenpalControlOptions.moods, id: \.tag) { mood in
                Button {
                    if mood.tag == "custom" {
                        customMoodDraft = settings.customMoodText
                        showCustomMoodEditor = true
                    } else {
                        settings.companionMood = mood.tag
                    }
                } label: {
                    Label(mood.title, systemImage:
                            settings.companionMood == mood.tag ? "checkmark" : mood.icon)
                }
            }
        } label: {
            Label(selectedMoodTitle, systemImage: "theatermasks")
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Companion mood, \(selectedMoodTitle)")
    }

    private var detailMenu: some View {
        Menu {
            ForEach(PenpalControlOptions.mathDetails, id: \.tag) { detail in
                Button {
                    settings.mathDetail = detail.tag
                } label: {
                    Label(detail.title, systemImage:
                            settings.mathDetail == detail.tag ? "checkmark" : detail.icon)
                }
            }
        } label: {
            Label(selectedDetailTitle, systemImage: "list.number")
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Solution detail, \(selectedDetailTitle)")
    }

    private var mathQuickToolsMenu: some View {
        Menu {
            Button("Plot a Function…", systemImage: "chart.xyaxis.line") {
                onPlotGraph()
            }
            Button("Solve Whole Page", systemImage: "list.number") {
                onSolveWholePage()
            }
            Button(rulerActive ? "Hide Ruler" : "Show Ruler",
                   systemImage: rulerActive ? "ruler.fill" : "ruler") {
                onToggleRuler()
            }
            Divider()
            Toggle("Instant \"=\" (Skip Chip)", isOn: Binding(
                get: { !settings.confirmBeforeSolving },
                set: { settings.confirmBeforeSolving = !$0 }
            ))
            Divider()
            Menu("Paper Style", systemImage: "squareshape.split.3x3") {
                ForEach([("grid", "Graph Grid", "squareshape.split.3x3"),
                         ("dots", "Dot Grid", "circle.grid.3x3"),
                         ("ruled", "Ruled", "line.3.horizontal"),
                         ("blank", "Blank", "doc")], id: \.0) { tag, title, icon in
                    Button {
                        settings.paperStyle = tag
                    } label: {
                        Label(title, systemImage: settings.paperStyle == tag ? "checkmark" : icon)
                    }
                }
            }
        } label: {
            Image(systemName: "function")
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Pen.inkPrimary)
        .disabled(activityPhase != nil)
        .accessibilityLabel("Math Tools")
        .accessibilityHint("Plot a function, solve the whole page, toggle ruler, or switch to grid paper")
    }

    private var languageMenu: some View {
        Menu {
            ForEach(PenpalControlOptions.languages, id: \.tag) { language in
                Button {
                    settings.targetLanguage = language.tag
                } label: {
                    Label(language.title, systemImage:
                            settings.targetLanguage == language.tag
                          ? "checkmark" : "character.bubble")
                }
            }
        } label: {
            Label(selectedLanguageTitle, systemImage: "globe")
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Practice language, \(selectedLanguageTitle)")
    }

    private var illustratorQualityMenu: some View {
        Menu {
            ForEach(PenpalControlOptions.illustratorQualities, id: \.tag) { quality in
                Button {
                    settings.illustratorQuality = quality.tag
                } label: {
                    Label(
                        quality.title,
                        systemImage: settings.illustratorQuality == quality.tag
                            ? "checkmark" : quality.icon
                    )
                }
            }
        } label: {
            Label(selectedIllustratorQualityTitle, systemImage: "sparkles")
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Illustration quality, \(selectedIllustratorQualityTitle)"
        )
    }
}
