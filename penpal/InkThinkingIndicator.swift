//
//  InkThinkingIndicator.swift
//  penpal
//
//  PEN-08 — ink-native progress.
//
//  A UIKit spinner on a page of handwriting announces "software is working".
//  This is a nib at work on paper: three ink dots laid down in sequence with
//  a wet-ink settle, at a tempo that matches what Penpal is actually doing.
//
//  Honours Reduce Motion (PEN-32): the animation becomes a calm opacity
//  breath rather than movement, and never stops conveying "busy".
//

import SwiftUI

struct InkThinkingIndicator: View {

    enum Phase {
        case reading    // scanning the user's ink
        case thinking   // model is working
        case writing    // laying down the reply

        /// Seconds per dot. Reading is quick and scanning; thinking is a slower,
        /// considered beat; writing keeps pace with the pen.
        var interval: Double {
            switch self {
            case .reading:  return 0.26
            case .thinking: return 0.42
            case .writing:  return 0.20
            }
        }

        var tint: Color {
            switch self {
            case .reading:  return Pen.inkAccent.opacity(0.75)
            case .thinking: return Pen.inkAccent
            case .writing:  return Pen.inkAccent.opacity(0.9)
            }
        }
    }

    var phase: Phase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tick = 0
    @State private var timer: Timer?

    private let dotCount = 3

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(phase.tint)
                    .frame(width: dotSize(index), height: dotSize(index))
                    .opacity(opacity(index))
                    .animation(.easeOut(duration: phase.interval * 0.8), value: tick)
            }
        }
        .frame(width: 26, alignment: .leading)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: phase) { _, _ in restart() }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Appearance

    /// Wet ink sits slightly proud when freshly laid, then settles.
    private func dotSize(_ index: Int) -> CGFloat {
        guard !reduceMotion else { return 4 }
        return isActive(index) ? 5.2 : 3.6
    }

    private func opacity(_ index: Int) -> Double {
        if reduceMotion {
            // No movement: the whole group breathes together.
            return tick % 2 == 0 ? 0.85 : 0.35
        }
        if isActive(index) { return 1 }
        // Dots already laid down this pass stay damp and fade behind the nib.
        let laid = tick % (dotCount + 1)
        return index < laid ? 0.5 : 0.18
    }

    private func isActive(_ index: Int) -> Bool {
        tick % (dotCount + 1) == index + 1
    }

    private var accessibilityText: String {
        switch phase {
        case .reading:  return "Reading your writing"
        case .thinking: return "Solving and verifying"
        case .writing:  return "Writing the reply"
        }
    }

    // MARK: - Timing

    private func start() {
        stop()
        // Reduce Motion gets a slow, steady breath rather than a running nib.
        let interval = reduceMotion ? 0.9 : phase.interval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in tick &+= 1 }
        }
        // Keep animating while the user scrolls the page.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restart() {
        tick = 0
        start()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        InkThinkingIndicator(phase: .reading)
        InkThinkingIndicator(phase: .thinking)
        InkThinkingIndicator(phase: .writing)
    }
    .padding()
}
