//
//  PenpalAnimatedLogo.swift
//  penpal
//
//  A resolution-independent, vector-animated Penpal brand mark:
//  a calligraphic lowercase 'p' that transitions into a fountain pen nib
//  with an authentic breather hole and ink slit.
//
//  Supports stroke-drawing reveal, breathing ink pulse, and interactive spring response.
//

import SwiftUI

// MARK: - Vector Mark Shape

/// Resolution-independent bezier shape of the Penpal fountain pen mark.
/// Derived from the brand master silhouette, normalized to 0...1.
struct PenpalMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let ox = rect.minX
        let oy = rect.minY

        @inline(__always) func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: ox + CGFloat(x) * w, y: oy + CGFloat(y) * h)
        }

        // Outer contour: calligraphic 'p' stem, crescent bowl, and fountain pen nib
        p.move(to: pt(0.38994, 0.89374))
        p.addCurve(to: pt(0.39678, 0.87932), control1: pt(0.39577, 0.89076), control2: pt(0.39672, 0.88876))
        p.addCurve(to: pt(0.39907, 0.86603), control1: pt(0.39683, 0.87227), control2: pt(0.39712, 0.87053))
        p.addCurve(to: pt(0.43053, 0.81539), control1: pt(0.40629, 0.84927), control2: pt(0.41703, 0.83198))
        p.addCurve(to: pt(0.45781, 0.77169), control1: pt(0.44040, 0.80325), control2: pt(0.44976, 0.78829))
        p.addCurve(to: pt(0.46364, 0.74900), control1: pt(0.46049, 0.76615), control2: pt(0.46270, 0.75765))
        p.addCurve(to: pt(0.46172, 0.73261), control1: pt(0.46497, 0.73680), control2: pt(0.46395, 0.73357))
        p.addCurve(to: pt(0.45048, 0.66224), control1: pt(0.45465, 0.70529), control2: pt(0.45051, 0.67945))
        p.addLine(to: pt(0.45381, 0.65710))
        p.addLine(to: pt(0.44940, 0.64537))
        p.addCurve(to: pt(0.42297, 0.45893), control1: pt(0.43472, 0.60613), control2: pt(0.42814, 0.55970))
        p.addCurve(to: pt(0.41938, 0.26268), control1: pt(0.41901, 0.38178), control2: pt(0.41731, 0.28858))
        p.addCurve(to: pt(0.43482, 0.21507), control1: pt(0.42137, 0.23763), control2: pt(0.42560, 0.22462))
        p.addCurve(to: pt(0.47326, 0.20654), control1: pt(0.44399, 0.20552), control2: pt(0.45587, 0.20290))
        p.addCurve(to: pt(0.50348, 0.20183), control1: pt(0.48974, 0.21005), control2: pt(0.49910, 0.20859))
        p.addCurve(to: pt(0.43580, 0.12560), control1: pt(0.51806, 0.17942), control2: pt(0.48444, 0.14155))
        p.addCurve(to: pt(0.30257, 0.17783), control1: pt(0.37258, 0.10490), control2: pt(0.32162, 0.12488))
        p.addCurve(to: pt(0.30054, 0.27057), control1: pt(0.29497, 0.19897), control2: pt(0.29408, 0.23929))
        p.addCurve(to: pt(0.30129, 0.27616), control1: pt(0.30097, 0.27268), control2: pt(0.30131, 0.27519))
        p.addLine(to: pt(0.30125, 0.27791))
        p.addLine(to: pt(0.29995, 0.27606))
        p.addCurve(to: pt(0.27186, 0.24318), control1: pt(0.29422, 0.26782), control2: pt(0.28081, 0.25213))
        p.addCurve(to: pt(0.09681, 0.18390), control1: pt(0.22153, 0.19284), control2: pt(0.15764, 0.17120))
        p.addCurve(to: pt(0.00000, 0.41005), control1: pt(0.04354, 0.20260), control2: pt(-0.01080, 0.29938))
        p.addCurve(to: pt(0.07565, 0.57959), control1: pt(0.00735, 0.48313), control2: pt(0.03836, 0.54774))
        p.addCurve(to: pt(0.21959, 0.58971), control1: pt(0.12066, 0.60297), control2: pt(0.17404, 0.60673))
        p.addCurve(to: pt(0.29894, 0.52034), control1: pt(0.25529, 0.57639), control2: pt(0.28401, 0.55127))
        p.addCurve(to: pt(0.30379, 0.48171), control1: pt(0.30884, 0.49981), control2: pt(0.31076, 0.48457))
        p.addCurve(to: pt(0.28868, 0.48947), control1: pt(0.30015, 0.48018), control2: pt(0.29759, 0.48150))
        p.addCurve(to: pt(0.21481, 0.51971), control1: pt(0.26627, 0.50952), control2: pt(0.24371, 0.51875))
        p.addCurve(to: pt(0.13156, 0.49015), control1: pt(0.18318, 0.52076), control2: pt(0.15651, 0.51129))
        p.addCurve(to: pt(0.07997, 0.38006), control1: pt(0.09633, 0.46029), control2: pt(0.07682, 0.41834))
        p.addCurve(to: pt(0.11894, 0.27982), control1: pt(0.08271, 0.34701), control2: pt(0.09756, 0.30856))
        p.addCurve(to: pt(0.23126, 0.25056), control1: pt(0.14713, 0.24192), control2: pt(0.19125, 0.22998))
        p.addCurve(to: pt(0.29762, 0.28740), control1: pt(0.25899, 0.26484), control2: pt(0.28634, 0.28014))
        p.addCurve(to: pt(0.30797, 0.30056), control1: pt(0.30034, 0.28915), control2: pt(0.30500, 0.29507))
        p.addCurve(to: pt(0.30949, 0.30702), control1: pt(0.31095, 0.30605), control2: pt(0.31154, 0.30857))
        p.addLine(to: pt(0.30800, 0.30702))
        p.addCurve(to: pt(0.30773, 0.34777), control1: pt(0.30718, 0.30702), control2: pt(0.30706, 0.32536))
        p.addCurve(to: pt(0.30250, 0.65586), control1: pt(0.30870, 0.37989), control2: pt(0.30689, 0.48517))
        p.addLine(to: pt(0.30263, 0.65750))
        p.addLine(to: pt(0.30777, 0.66535))
        p.addCurve(to: pt(0.31018, 0.74107), control1: pt(0.31885, 0.68228), control2: pt(0.31976, 0.71077))
        p.addCurve(to: pt(0.30407, 0.76356), control1: pt(0.30691, 0.75139), control2: pt(0.30472, 0.75945))
        p.addCurve(to: pt(0.28045, 0.79155), control1: pt(0.30248, 0.77353), control2: pt(0.29579, 0.78160))
        p.addCurve(to: pt(0.22955, 0.85415), control1: pt(0.25732, 0.80655), control2: pt(0.24056, 0.82718))
        p.addCurve(to: pt(0.22225, 0.87675), control1: pt(0.22384, 0.86812), control2: pt(0.22129, 0.87455))
        p.addCurve(to: pt(0.22855, 0.89370), control1: pt(0.22325, 0.87900), control2: pt(0.22639, 0.88748))
        p.addCurve(to: pt(0.25279, 0.87815), control1: pt(0.23164, 0.90259), control2: pt(0.23668, 0.89980))
        p.addCurve(to: pt(0.27472, 0.84151), control1: pt(0.26002, 0.86841), control2: pt(0.26768, 0.85564))
        p.addCurve(to: pt(0.28828, 0.82580), control1: pt(0.27732, 0.83628), control2: pt(0.28342, 0.82921))
        p.addLine(to: pt(0.29709, 0.81962))
        p.addLine(to: pt(0.29713, 0.82368))
        p.addCurve(to: pt(0.30399, 0.84597), control1: pt(0.29718, 0.82938), control2: pt(0.29994, 0.83842))
        p.addCurve(to: pt(0.38994, 0.89374), control1: pt(0.32488, 0.88486), control2: pt(0.36427, 0.90673))
        p.closeSubpath()

        // Inner contour: nib breather hole and vertical ink slit
        p.move(to: pt(0.38299, 0.86786))
        p.addCurve(to: pt(0.38870, 0.77353), control1: pt(0.38652, 0.86918), control2: pt(0.38732, 0.86125))
        p.addLine(to: pt(0.38965, 0.73507))
        p.addCurve(to: pt(0.40192, 0.74864), control1: pt(0.39309, 0.73365), control2: pt(0.39869, 0.74003))
        p.addCurve(to: pt(0.40321, 0.76359), control1: pt(0.40418, 0.75438), control2: pt(0.40433, 0.75841))
        p.addCurve(to: pt(0.39703, 0.77257), control1: pt(0.40102, 0.76763), control2: pt(0.39722, 0.77163))
        p.addLine(to: pt(0.39459, 0.77518))
        p.addLine(to: pt(0.39459, 0.86786))
        p.addCurve(to: pt(0.38299, 0.86786), control1: pt(0.39200, 0.87100), control2: pt(0.38550, 0.87100))
        p.closeSubpath()

        return p
    }
}

// MARK: - Animated Penpal Logo View

/// A high-craft animated representation of the Penpal brand mark.
/// Plays an organic drawing-and-ink-fill sequence, breathes in loading states,
/// and responds with tactile spring dynamics when tapped.
struct PenpalAnimatedLogoView: View {
    enum Mode {
        /// Reveals contour via stroke animation, then flows ink into the fill.
        case drawAndFill
        /// Continuous gentle rhythmic breathing (perfect for loading / thinking).
        case breathing
        /// Pristine static mark that springs and shines on tap.
        case interactive
    }

    var size: CGFloat = 64
    var mode: Mode = .drawAndFill
    var tintColor: Color = Pen.inkAccent
    var autoPlay: Bool = true
    var onTapped: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var strokeProgress: CGFloat = 0
    @State private var fillOpacity: Double = 0
    @State private var breathScale: CGFloat = 1.0
    @State private var breathGlow: Double = 0.3
    @State private var isPressed: Bool = false
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        ZStack {
            // Ambient ink glow around the nib
            RadialGradient(
                colors: [
                    tintColor.opacity(breathGlow * 0.45),
                    tintColor.opacity(0)
                ],
                center: UnitPoint(x: 0.39, y: 0.82),
                startRadius: 2,
                endRadius: size * 0.55
            )
            .frame(width: size * 1.5, height: size * 1.5)
            .blur(radius: 8)
            .opacity(fillOpacity > 0.2 ? 1 : 0)

            // Ink fill layer (EvenOdd rule preserves breather hole and slit)
            PenpalMarkShape()
                .fill(
                    LinearGradient(
                        colors: [
                            tintColor,
                            tintColor.opacity(0.88)
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    style: FillStyle(eoFill: true, antialiased: true)
                )
                .opacity(fillOpacity)

            // Shimmer highlight sweeping across the calligraphic bowl
            PenpalMarkShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.28),
                            Color.white.opacity(0)
                        ],
                        startPoint: UnitPoint(x: shimmerPhase - 0.4, y: shimmerPhase - 0.4),
                        endPoint: UnitPoint(x: shimmerPhase + 0.4, y: shimmerPhase + 0.4)
                    ),
                    style: FillStyle(eoFill: true, antialiased: true)
                )
                .opacity(fillOpacity > 0.8 ? 1 : 0)

            // Outline drawing stroke
            PenpalMarkShape()
                .trim(from: 0, to: strokeProgress)
                .stroke(
                    tintColor,
                    style: StrokeStyle(lineWidth: max(1.5, size * 0.035), lineCap: .round, lineJoin: .round)
                )

            // Nib tip spark: a microscopic pin-light on the iridium point
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: max(2.5, size * 0.04), height: max(2.5, size * 0.04))
                .position(x: size * 0.39, y: size * 0.895)
                .opacity(strokeProgress > 0.6 ? breathGlow : 0)
                .blur(radius: 0.8)
        }
        .frame(width: size, height: size)
        .scaleEffect((isPressed ? 0.94 : 1.0) * breathScale)
        .contentShape(Rectangle())
        .onTapGesture {
            Pen.tapHaptic()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    isPressed = false
                }
            }
            triggerShimmer()
            onTapped?()
        }
        .onAppear {
            if reduceMotion {
                strokeProgress = 1
                fillOpacity = 1
                return
            }
            startAnimation()
        }
    }

    private func startAnimation() {
        switch mode {
        case .drawAndFill:
            strokeProgress = 0
            fillOpacity = 0
            withAnimation(.easeInOut(duration: 0.85)) {
                strokeProgress = 1.0
            }
            withAnimation(.easeOut(duration: 0.65).delay(0.55)) {
                fillOpacity = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
                startBreathing()
            }

        case .breathing:
            strokeProgress = 1.0
            fillOpacity = 1.0
            startBreathing()

        case .interactive:
            strokeProgress = 1.0
            fillOpacity = 1.0
            shimmerPhase = -0.5
        }
    }

    private func startBreathing() {
        guard !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: 2.2)
            .repeatForever(autoreverses: true)
        ) {
            breathScale = 1.035
            breathGlow = 0.75
        }
    }

    private func triggerShimmer() {
        guard !reduceMotion else { return }
        shimmerPhase = -0.4
        withAnimation(.easeOut(duration: 0.75)) {
            shimmerPhase = 1.4
        }
    }
}

// MARK: - Animated Brand Signature

/// Replaces the static PenBrandSignature with the animated vector mark + editorial wordmark.
struct PenBrandAnimatedSignature: View {
    var markSize: CGFloat = 42
    var mode: PenpalAnimatedLogoView.Mode = .drawAndFill

    var body: some View {
        HStack(spacing: 8) {
            PenpalAnimatedLogoView(size: markSize, mode: mode)
            VStack(alignment: .leading, spacing: -2) {
                Text("penpal")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Pen.inkPrimary)
                Text("INK STUDIO")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Pen.inkAccent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Penpal Ink Studio")
    }
}

#Preview {
    VStack(spacing: 40) {
        PenpalAnimatedLogoView(size: 120, mode: .drawAndFill)
        PenBrandAnimatedSignature(markSize: 52)
    }
    .padding(40)
    .background(Pen.paper)
}
