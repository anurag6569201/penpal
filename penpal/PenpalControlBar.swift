//
//  PenpalControlBar.swift
//  penpal
//
//  Persistent, in-context controls for who Penpal is and how it replies.
//

import SwiftUI

enum PenpalControlOptions {
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
}

struct PenpalControlBar: View {
    @ObservedObject var settings: HandwritingSettings
    var activityPhase: InkThinkingIndicator.Phase?
    var statusText: String?
    var onClose: () -> Void

    @State private var showCustomMoodEditor = false
    @State private var customMoodDraft = ""

    private var isMathematician: Bool {
        settings.capability == "mathematician"
    }

    private var selectedMoodTitle: String {
        PenpalControlOptions.moods.first { $0.tag == settings.companionMood }?.title
            ?? "Mood"
    }

    private var selectedDetailTitle: String {
        PenpalControlOptions.mathDetails.first { $0.tag == settings.mathDetail }?.title
            ?? "Detail"
    }

    var body: some View {
        HStack(spacing: 8) {
            if activityPhase != nil || statusText != nil {
                statusSection
                Divider().frame(height: 24)
            }

            capabilityButton(
                title: "Companion",
                icon: "heart.text.square",
                tag: "companion"
            )
            capabilityButton(
                title: "Mathematician",
                icon: "x.squareroot",
                tag: "mathematician"
            )

            Divider().frame(height: 24)

            if isMathematician {
                detailMenu
            } else {
                moodMenu
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Turn off Penpal mode")
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Penpal status")
        .accessibilityValue(statusText ?? "Working")
    }

    private func capabilityButton(title: String, icon: String, tag: String) -> some View {
        let selected = settings.capability == tag
        return Button {
            settings.capability = tag
        } label: {
            Label(title, systemImage: icon)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Pen.inkAccent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
}
