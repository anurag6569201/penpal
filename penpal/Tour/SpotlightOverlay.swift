//
//  SpotlightOverlay.swift
//  penpal
//
//  Full-screen spotlight overlay with even-odd cutout, dashed animated ring,
//  an intelligent callout card, and an interactive "Try In This Space" playground.
//

import SwiftUI

struct SpotlightOverlay: View {
    @ObservedObject var coordinator = TourCoordinator.shared
    let anchors: [TourAnchorID: Anchor<CGRect>]
    let proxy: GeometryProxy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashPhase: CGFloat = 0

    private var currentStep: TourStep { coordinator.currentStep }

    var body: some View {
        if coordinator.isActive {
            ZStack {
                let targetRect = resolveTargetRect()

                // Dimmed backdrop with cutout
                SpotlightMask(targetRect: targetRect)
                    .fill(style: FillStyle(eoFill: true))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .ignoresSafeArea()
                    .contentShape(SpotlightMask(targetRect: targetRect), eoFill: true)
                    .allowsHitTesting(targetRect == nil) // Allow taps through cutout to target control

                // If anchor is .page, render the interactive "Try In This Space" overlay pad
                if let targetRect, currentStep.anchor == .page {
                    tryPadOverlay(targetRect: targetRect)
                }

                // Accent ring around target
                if let targetRect {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            Pen.inkAccent,
                            style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                dash: [8, 6],
                                dashPhase: dashPhase
                            )
                        )
                        .frame(width: targetRect.width, height: targetRect.height)
                        .position(x: targetRect.midX, y: targetRect.midY)
                        .allowsHitTesting(false)
                        .animation(reduceMotion ? nil : Pen.spring, value: targetRect)
                }

                // Callout Card
                calloutCard(targetRect: targetRect)
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : Pen.spring, value: coordinator.currentIndex)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    dashPhase = -28
                }
            }
        }
    }

    // MARK: - Rect Resolution

    private func resolveTargetRect() -> CGRect? {
        guard let anchorID = currentStep.anchor else {
            return nil
        }

        // Special handling: page surface provides an explicit interactive practice arena
        if anchorID == .page {
            let width = min(proxy.size.width - 64, 620)
            let height: CGFloat = 280
            let x = proxy.size.width / 2 - width / 2
            let y = proxy.size.height / 2 + 50
            return CGRect(x: x, y: y, width: width, height: height)
        }

        guard let anchor = anchors[anchorID] else { return nil }
        let raw = proxy[anchor]
        guard raw.width > 0 && raw.height > 0 else { return nil }

        return raw.insetBy(dx: -8, dy: -8)
    }

    // MARK: - Interactive Try Pad Overlay

    @ViewBuilder
    private func tryPadOverlay(targetRect: CGRect) -> some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.outline")
                        .font(.caption2.weight(.bold))
                    Text("TRY IN THIS SPACE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.4)
                }
                .foregroundStyle(Pen.inkAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Pen.accentWash, in: Capsule())

                Spacer()

                if let celebrated = coordinator.celebratedEvent {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(celebrationMessage(for: celebrated))
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Pen.inkAccent, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Text("Draw directly over this box with your pen")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Pen.inkFaded)
                }
            }

            Spacer()

            // Prompt content
            switch currentStep.id {
            case "box_gesture":
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.draw.fill")
                        Text("TRY IT ON THE PAGE")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Pen.inkAccent)
                    Text("Draw a box around the handwritten question on the page with your pen ➔")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pen.inkPrimary)
                }

            case "strike_gesture":
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "strikethrough")
                        Text("TRY IT ON THE PAGE")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Color.red.opacity(0.85))
                    Text("Draw a horizontal line across the handwritten words to erase them in a puff ➔")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pen.inkPrimary)
                }

            case "equals_math":
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "equal.circle.fill")
                        Text("TRY IT ON THE PAGE")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(Pen.inkAccent)
                    Text("Write = right after the handwritten calculation on the page and pause ➔")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pen.inkPrimary)
                }

            default:
                VStack(spacing: 6) {
                    Text("Write freely on this page")
                        .font(Pen.titleSerif)
                        .foregroundStyle(Pen.inkPrimary.opacity(0.7))
                    Text("Penpal reads your handwriting and writes back on paper")
                        .font(.footnote)
                        .foregroundStyle(Pen.inkFaded)
                }
            }

            Spacer()
        }
        .padding(18)
        .frame(width: targetRect.width, height: targetRect.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Pen.paper.opacity(0.92))
        )
        .position(x: targetRect.midX, y: targetRect.midY)
        .allowsHitTesting(false) // Direct touch passthrough into PencilKit!
        .animation(reduceMotion ? nil : Pen.spring, value: currentStep.id)
    }

    // MARK: - Callout Card

    private func calloutCard(targetRect: CGRect?) -> some View {
        let cardWidth: CGFloat = min(420, proxy.size.width - 48)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PENPAL TOUR")
                    .font(.caption2.weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(Pen.inkAccent)
                Spacer()
                Text(coordinator.progressText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Pen.inkFaded)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(currentStep.title)
                    .font(Pen.titleSerif)
                    .foregroundStyle(Pen.inkPrimary)
                Text(currentStep.body)
                    .font(Pen.body)
                    .foregroundStyle(Pen.inkPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let celebrated = coordinator.celebratedEvent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.bold))
                    Text(celebrationMessage(for: celebrated))
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Pen.inkAccent, in: RoundedRectangle(cornerRadius: 10))
                .transition(.scale.combined(with: .opacity))
            } else if let tryPrompt = currentStep.tryItPrompt {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.caption.weight(.semibold))
                    Text(tryPrompt)
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(Pen.inkAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Pen.accentWash, in: RoundedRectangle(cornerRadius: 8))
            }

            // Progress dots
            HStack(spacing: 4) {
                ForEach(0..<coordinator.steps.count, id: \.self) { idx in
                    Capsule()
                        .fill(idx == coordinator.currentIndex ? Pen.inkAccent : Pen.inkPrimary.opacity(0.15))
                        .frame(width: idx == coordinator.currentIndex ? 16 : 5, height: 5)
                        .animation(reduceMotion ? nil : Pen.spring, value: coordinator.currentIndex)
                }
            }
            .padding(.top, 2)

            // Buttons
            HStack(spacing: 12) {
                Button("Skip Tour") {
                    coordinator.skip()
                }
                .font(Pen.sub)
                .foregroundStyle(Pen.inkFaded)

                Spacer()

                if coordinator.currentIndex > 0 {
                    Button {
                        coordinator.back()
                    } label: {
                        Text("Back")
                            .font(Pen.sub.weight(.medium))
                            .foregroundStyle(Pen.inkPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(Pen.paper, in: Capsule())
                            .overlay(Capsule().strokeBorder(Pen.inkPrimary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    coordinator.next()
                } label: {
                    Text(coordinator.currentIndex == coordinator.steps.count - 1 ? "Finish" : "Next")
                        .font(Pen.sub.weight(.semibold))
                        .foregroundStyle(Pen.onAccent)
                        .padding(.horizontal, 20)
                        .frame(height: 38)
                        .background(Pen.inkAccent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: cardWidth)
        .background(Pen.paperRaised, in: RoundedRectangle(cornerRadius: Pen.radiusCard, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .position(calculateCardPosition(targetRect: targetRect, cardWidth: cardWidth))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(currentStep.title), \(coordinator.progressText)")
    }

    private func calculateCardPosition(targetRect: CGRect?, cardWidth: CGFloat) -> CGPoint {
        guard let targetRect else {
            return CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }

        let cardHeight: CGFloat = 260
        let padding: CGFloat = 20

        // If target is in bottom half, place card above it
        if targetRect.midY > proxy.size.height / 2 {
            let y = max(cardHeight / 2 + padding + 60, targetRect.minY - cardHeight / 2 - padding)
            let x = max(cardWidth / 2 + padding, min(proxy.size.width - cardWidth / 2 - padding, targetRect.midX))
            return CGPoint(x: x, y: y)
        } else {
            // Target is in top half, place card below it
            let y = min(proxy.size.height - cardHeight / 2 - padding, targetRect.maxY + cardHeight / 2 + padding)
            let x = max(cardWidth / 2 + padding, min(proxy.size.width - cardWidth / 2 - padding, targetRect.midX))
            return CGPoint(x: x, y: y)
        }
    }

    private func celebrationMessage(for event: TourEvent) -> String {
        switch event {
        case .boxDrawn:
            return "✓ Box detected! Penpal is reading..."
        case .strikeDone:
            return "✓ Word erased! Fast & effortless!"
        case .equalsSolved:
            return "✓ Math solved instantly on-device!"
        case .penpalToggled:
            return "✓ Penpal mode activated!"
        case .checkWorkDone:
            return "✓ Math checked line-by-line!"
        case .askTapped:
            return "✓ Sent to Penpal!"
        case .blockInserted:
            return "✓ Block added to page!"
        }
    }
}

// MARK: - Cutout Shape

private struct SpotlightMask: Shape {
    var targetRect: CGRect?

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            let r = targetRect ?? .zero
            return AnimatablePair(AnimatablePair(r.origin.x, r.origin.y), AnimatablePair(r.size.width, r.size.height))
        }
        set {
            targetRect = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second
            )
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)

        if let target = targetRect, target.width > 0, target.height > 0 {
            path.addRoundedRect(in: target, cornerSize: CGSize(width: 14, height: 14), style: .continuous)
        }

        return path
    }
}
