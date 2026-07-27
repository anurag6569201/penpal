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
        ("illustrator", "Illustrator", "pencil.and.outline"),
        ("language", "Language Partner", "character.bubble"),
        ("debate", "Debate Partner", "arrow.left.arrow.right"),
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
        HStack(spacing: 8) {
            if activityPhase != nil || statusText != nil {
                statusSection
                Divider().frame(height: 24)
            }

            capabilityMenu

            if hasSecondaryControls {
                Divider().frame(height: 24)
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
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Pen.inkPrimary)
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
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Pen.inkFaded)
            .accessibilityLabel("Turn off Penpal mode")
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Pen.paperRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Pen.inkAccent.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
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
                .padding(.horizontal, 10)
                .frame(height: 32)
                .foregroundStyle(Color.white)
                .background(Pen.inkAccent, in: Capsule())
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
                .frame(height: 32)
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
                .frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Solution detail, \(selectedDetailTitle)")
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
                .frame(height: 32)
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
                .frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Illustration quality, \(selectedIllustratorQualityTitle)"
        )
    }
}
