//
//  DesignSystem.swift
//  penpal
//
//  The "Ink Studio" design language — see DESIGN.md for the reasoning.
//
//  One metaphor, applied everywhere: a good notebook and a fountain pen.
//  Components take SEMANTIC tokens from here and never name raw colours,
//  so a palette change is one edit and the app can never drift into three
//  slightly different accents.
//

import SwiftUI
import UIKit

// MARK: - Colour tokens

enum Pen {

    /// Warm cream in light mode, true AMOLED black in dark mode — the
    /// deepest layer, the canvas itself.
    static let paper = Color(
        light: Color(red: 247/255, green: 244/255, blue: 237/255),
        dark: .black)

    /// Cards, sheets, toolbars — sits ON the paper, so it needs to read as
    /// a distinct surface, not vanish into it.
    /// Light: a hair below pure white, so raised surfaces don't glare next
    /// to the soft cream page. Dark: a bare lift off true black (not grey —
    /// still reads as black at a glance) so elevation comes from the
    /// surface itself, not only from a shadow that barely shows on OLED.
    static let paperRaised = Color(
        light: Color(red: 255/255, green: 253/255, blue: 249/255),
        dark: Color(red: 14/255, green: 13/255, blue: 16/255))

    /// Text and drawn ink.
    static let inkPrimary = Color(
        light: Color(red: 26/255, green: 43/255, blue: 42/255),
        dark: Color(red: 236/255, green: 234/255, blue: 228/255))

    /// Penpal's presence: actions, its pen, its highlights. ONE accent per
    /// screen — a page with three accent colours is a dashboard.
    static let inkAccent = Color(
        light: Color(red: 27/255, green: 93/255, blue: 86/255),
        dark: Color(red: 126/255, green: 206/255, blue: 185/255))

    static let accentWash = inkAccent.opacity(0.10)
    static let onAccent = Color(light: .white, dark: Color(red: 10/255, green: 36/255, blue: 31/255))

    /// Secondary text. Derived, not a separate hue.
    static let inkFaded = inkPrimary.opacity(0.68)

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

    /// An editorial serif wordmark complements the handwritten page.
    static func brand(_ size: CGFloat = 44) -> Font {
        Font.system(size: size, weight: .semibold, design: .serif)
    }

    /// Serif headings read as print on paper.
    static let titleSerif = Font.system(.title, design: .serif, weight: .semibold)
    static let headline = Font.system(.headline)
    static let body = Font.system(.body)
    static let sub = Font.system(.subheadline)
    static let caption = Font.system(.footnote)

    // MARK: Shape & depth

    /// Continuous corners only — paper has soft corners.
    static let radiusControl: CGFloat = 10
    static let radiusCard: CGFloat = 20
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Pen.headline)
            .foregroundStyle(Pen.onAccent)
            .frame(maxWidth: .infinity, minHeight: Pen.touchTarget)
            .contentShape(Capsule())
            .background(Pen.inkAccent, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : Pen.spring, value: configuration.isPressed)
    }
}

/// Tinted border capsule for meaningful-but-secondary actions.
struct PenSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Pen.headline)
            .foregroundStyle(Pen.inkAccent)
            .frame(maxWidth: .infinity, minHeight: Pen.touchTarget)
            .background(
                Capsule().strokeBorder(Pen.inkAccent.opacity(0.45), lineWidth: 1.5))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : Pen.spring, value: configuration.isPressed)
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

// MARK: - Brand signature

/// Use the master silhouette as a template so it stays crisp in either appearance.
/// The supplied master includes its own optical clear space; do not crop it.
struct PenBrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image("PenpalMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Pen.inkAccent)
            .accessibilityHidden(true)
    }
}

struct PenBrandSignature: View {
    @ScaledMetric(relativeTo: .title2) private var markSize: CGFloat = 44
    var body: some View {
        HStack(spacing: 4) {
            PenBrandMark(size: markSize)
            Text("penpal")
                .font(.system(.title2, design: .serif, weight: .semibold))
                .tracking(-0.7)
                .foregroundStyle(Pen.inkPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Penpal")
    }
}
