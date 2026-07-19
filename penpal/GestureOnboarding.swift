//
//  GestureOnboarding.swift
//  penpal
//
//  PEN-33 — teach the gestures, on the page, by drawing one.
//
//  The box gesture is the best idea in this product and nothing tells anyone
//  it exists. Same now for the double underline and strike-through. A feature
//  nobody discovers may as well not have shipped.
//
//  Design decisions:
//
//  * **On the page, not in a modal.** A carousel explaining a drawing gesture
//    is a contradiction. The user learns by drawing the thing once, on the
//    real surface, with their real pen.
//  * **One gesture, not four.** Boxing is the highest-value and most general.
//    Teach it, then get out of the way; the others surface as hints later,
//    when the user is already fluent. A four-step tour would be skipped.
//  * **Skippable, never repeated, never blocking.** It appears once, can be
//    dismissed instantly, and never interrupts an existing note — only an
//    empty page, where there is nothing to interrupt.
//  * **It disappears the moment they try.** The prompt is not "well done",
//    it is silence: the gesture itself does something, and that IS the
//    feedback. Congratulating someone for drawing a rectangle is patronising.
//

// ObservableObject / @Published. SwiftUI does not re-export Combine under
// explicit modules, so the conformance must be named.
import Combine
import SwiftUI

@MainActor
final class GestureOnboarding: ObservableObject {

    static let shared = GestureOnboarding()

    private let seenKey = "penpal.onboarding.boxGesture.v1"
    private let attemptsKey = "penpal.onboarding.boxGesture.attempts"

    /// Shown at most this many times. Someone who ignored it twice is not
    /// going to be won over by a third; nagging costs more than the feature.
    private static let maxShows = 2

    @Published private(set) var isShowing = false

    var hasLearned: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    private var timesShown: Int {
        get { UserDefaults.standard.integer(forKey: attemptsKey) }
        set { UserDefaults.standard.set(newValue, forKey: attemptsKey) }
    }

    private init() {}

    /// Called when the page becomes ready. `hasInk` guards the "never
    /// interrupt real work" rule.
    func offerIfAppropriate(penpalOn: Bool, isMathematician: Bool, hasInk: Bool) {
        guard penpalOn, isMathematician, !hasInk,
              !hasLearned, timesShown < Self.maxShows else { return }
        timesShown += 1
        withAnimation(.easeOut(duration: 0.4)) { isShowing = true }
    }

    /// The user drew a box — they've got it. Never show this again.
    func markLearned() {
        UserDefaults.standard.set(true, forKey: seenKey)
        dismiss()
    }

    func dismiss() {
        guard isShowing else { return }
        withAnimation(.easeIn(duration: 0.25)) { isShowing = false }
    }

    /// Testing / "show me again" from Settings.
    func reset() {
        UserDefaults.standard.removeObject(forKey: seenKey)
        UserDefaults.standard.removeObject(forKey: attemptsKey)
    }
}

/// A hand-drawn hint that sits on the page: a dashed box around a sample
/// problem, with one line of explanation. Rendered in ink-like strokes so it
/// belongs to the paper rather than floating above it as chrome.
struct BoxGestureHint: View {

    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Text("3x + 5 = 17")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(.primary.opacity(0.75))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Pen.inkAccent.opacity(0.65),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                           dash: [6, 5], dashPhase: phase))
            }
            .fixedSize()

            Text("Draw a box around any problem\nand Penpal solves it.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Got it", action: onDismiss)
                .font(.footnote.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Pen.inkAccent)
        }
        .padding(20)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .onAppear {
            // The travelling dash reads as "draw this". Under Reduce Motion it
            // holds still — the dashed outline alone still says "trace me".
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = -22
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: draw a box around any problem and Penpal solves it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss", onDismiss)
    }
}
