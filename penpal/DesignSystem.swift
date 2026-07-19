//
//  DesignSystem.swift
//  penpal
//
//  The "Warm Paper" design language — see DESIGN.md for the reasoning.
//
//  One metaphor, applied everywhere: a good notebook and a fountain pen.
//  Components take SEMANTIC tokens from here and never name raw colours,
//  so a palette change is one edit and the app can never drift into three
//  slightly different indigos.
//

import SwiftUI
import UIKit

// MARK: - Colour tokens

enum Pen {

    /// Warm cream / warm charcoal. Dark mode is dark PAPER, not OLED black —
    /// pure black would kill the paper metaphor the whole app rests on.
    static let paper = Color(
        light: Color(red: 0.980, green: 0.969, blue: 0.941),
        dark: Color(red: 0.110, green: 0.106, blue: 0.125))

    /// Cards and sheets sitting on the paper.
    static let paperRaised = Color(
        light: .white,
        dark: Color(red: 0.149, green: 0.145, blue: 0.169))

    /// Text and drawn ink.
    static let inkPrimary = Color(
        light: Color(red: 0.169, green: 0.165, blue: 0.200),
        dark: Color(red: 0.925, green: 0.918, blue: 0.894))

    /// Penpal's presence: actions, its pen, its highlights. ONE accent per
    /// screen — a page with three accent colours is a dashboard.
    static let inkAccent = Color(
        light: Color(red: 0.290, green: 0.306, blue: 0.620),
        dark: Color(red: 0.545, green: 0.561, blue: 0.851))

    /// Secondary text. Derived, not a separate hue.
    static let inkFaded = inkPrimary.opacity(0.55)

    /// Verified / success. Appears only as MEANING, never decoration.
    static let inkPositive = Color(
        light: Color(red: 0.180, green: 0.431, blue: 0.306),
        dark: Color(red: 0.498, green: 0.749, blue: 0.627))

    /// Offline / degraded / caution.
    static let inkCaution = Color(
        light: Color(red: 0.690, green: 0.486, blue: 0.173),
        dark: Color(red: 0.851, green: 0.659, blue: 0.361))

    /// Ruled lines and separators.
    static let rule = inkPrimary.opacity(0.12)

    // MARK: Typography — stationery, not software.

    /// The wordmark and brand moments: the product's promise is handwriting,
    /// so the brand is written, not set.
    static func brand(_ size: CGFloat = 44) -> Font {
        Font.custom("SnellRoundhand-Bold", size: size)
    }

    /// Serif headings read as print on paper.
    static let titleSerif = Font.system(size: 28, weight: .semibold, design: .serif)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 17)
    static let sub = Font.system(size: 15)
    static let caption = Font.system(size: 13)

    // MARK: Shape & depth

    /// Continuous corners only — paper has soft corners.
    static let radiusControl: CGFloat = 10
    static let radiusCard: CGFloat = 16
    static let radiusSheet: CGFloat = 22

    /// The standard spring. One curve everywhere is what makes the app feel
    /// like one object instead of a collection of screens.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.86)

    /// Minimum hit target.
    static let touchTarget: CGFloat = 48

    // MARK: Haptics

    /// A soft tap for acknowledgements; never for errors (the error message
    /// is the feedback — buzzing at a student who got something wrong is
    /// exactly the wrong tone).
    static func tapHaptic() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}

// MARK: - Light/dark initialiser

extension Color {
    /// A colour with explicit light and dark variants, resolved by trait.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Buttons (the only three)

/// Filled accent capsule. ONE per screen, maximum — it marks the single
/// thing we most want the user to do.
struct PenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Pen.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Pen.touchTarget)
            .background(Pen.inkAccent, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Pen.spring, value: configuration.isPressed)
    }
}

/// Tinted border capsule for meaningful-but-secondary actions.
struct PenSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Pen.headline)
            .foregroundStyle(Pen.inkAccent)
            .frame(maxWidth: .infinity, minHeight: Pen.touchTarget)
            .background(
                Capsule().strokeBorder(Pen.inkAccent.opacity(0.45), lineWidth: 1.5))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Pen.spring, value: configuration.isPressed)
    }
}

/// Text-only, for "not now" paths. Declining must always be visually easy —
/// a design that shrinks or greys the decline path is a dark pattern.
struct PenQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Pen.sub.weight(.medium))
            .foregroundStyle(Pen.inkFaded)
            .frame(minHeight: Pen.touchTarget)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Card

/// A paper card: raised surface, continuous corners, paper shadow (large
/// radius, very low opacity, always downward). Never border + shadow.
struct PaperCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Pen.paperRaised,
                        in: RoundedRectangle(cornerRadius: Pen.radiusCard,
                                             style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
    }
}

extension View {
    func paperCard() -> some View { modifier(PaperCard()) }
}

// MARK: - Ruled paper backdrop

/// The landing page IS a page: cream paper with ruled lines. Drawn, not an
/// image, so it adapts to any size and both appearances.
struct RuledPaperBackground: View {
    var lineGap: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Pen.paper
                Canvas { context, size in
                    var y = lineGap * 2
                    while y < size.height {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(Pen.rule), lineWidth: 1)
                        y += lineGap
                    }
                    // The classic margin line.
                    var margin = Path()
                    margin.move(to: CGPoint(x: 56, y: 0))
                    margin.addLine(to: CGPoint(x: 56, y: size.height))
                    context.stroke(margin, with: .color(Pen.inkCaution.opacity(0.25)),
                                   lineWidth: 1)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }
}
