//
//  CalibrationView.swift
//  penpal
//
//  "Teach it your hand" — train individual letters, digits, and marks.
//  Replies are composed letter by letter from these, so sizing stays even
//  no matter what text is generated. Each letter keeps up to 3 samples for
//  natural variation; write the same one again to add another sample.
//

import SwiftUI
import PencilKit

// MARK: - Vertical metric zones

/// Which guide lines a character is expected to touch — same idea as a
/// foundry's vertical metrics (x-height, ascender, descender, cap height).
/// Used to HIGHLIGHT the relevant guides and to give soft advice; never to
/// reject or reshape ink. Consistent personal quirks stay untouched.
enum GlyphZoneClass {
    case xHeight      // a c e m n o r s u v w x z
    case ascender     // b d f h k l t
    case descender    // g j p q y
    case cap          // capitals & digits
    case mark         // punctuation — exempt

    // Pure function on a Character — no UI state, safe from any context.
    nonisolated static func of(_ ch: Character) -> GlyphZoneClass {
        guard ch.isLetter || ch.isNumber else { return .mark }
        if ch.isUppercase || ch.isNumber { return .cap }
        switch ch.lowercased().first ?? ch {
        case "b", "d", "f", "h", "k", "l", "t": return .ascender
        case "g", "j", "p", "q", "y": return .descender
        default: return .xHeight
        }
    }
}

// MARK: - Guided drawing cell (UIKit)

final class GuidedCanvasView: UIView {

    let canvas = PKCanvasView()

    // Compact cell — fits a sheet without burying the chip grid.
    // Store normalizes against these at capture time (unit space is stable).
    // Metrics sized for NATURAL writing (~12mm x-height): oversized cells
    // make people draw with the arm instead of the fingers/wrist, which
    // captures the wrong timing and curvature entirely.
    // Zone ratios follow ruled school paper: the midline sits exactly halfway
    // between the top line and the baseline (equal ascender and body zones).
    // Sized to TRUE handwriting scale: x-height 20pt ≈ 3.8mm, full ascender
    // height ≈ 7.7mm — matching college-ruled paper (7.1mm), because writing
    // bigger than natural changes the hand's real timing and shapes.
    static let cellHeight: CGFloat = 84
    static let baselineY: CGFloat = 54
    static let xHeight: CGFloat = 20   // midline at y 34 = center of 14…54
    static let descenderY: CGFloat = 71
    /// Ascender/cap line, one full body-zone above the midline.
    static let ascenderY: CGFloat = 14

    /// What's being trained — a single character or a whole word. The zones
    /// its letters actually use light up so the eye is guided to the right
    /// lines before the pen touches.
    var targetText: String? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.masksToBounds = true
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = HandwritingSettings.shared.pencilOnly ? .pencilOnly : .default
        // Pen width scaled with the smaller x-height so normalized pressure
        // (width / xHeight) stays in the same range as older captures.
        canvas.tool = PKInkingTool(.pen, color: .label, width: 1.2)
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        func line(_ y: CGFloat, color: UIColor, dashed: Bool, strong: Bool) {
            ctx.setStrokeColor(color.withAlphaComponent(strong ? 0.85 : 0.16).cgColor)
            ctx.setLineWidth(strong ? 1.6 : 1)
            ctx.setLineDash(phase: 0, lengths: dashed ? [4, 4] : [])
            ctx.move(to: CGPoint(x: 16, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width - 16, y: y))
            ctx.strokePath()
        }

        // Which lines matter for this target?
        var ascStrong = false, xStrong = true, baseStrong = true, descStrong = false
        if let text = targetText, !text.isEmpty {
            if text.count == 1, let ch = text.first {
                switch GlyphZoneClass.of(ch) {
                case .xHeight:
                    xStrong = true
                case .ascender, .cap:
                    ascStrong = true
                    xStrong = false
                case .descender:
                    descStrong = true
                case .mark:
                    xStrong = false
                    baseStrong = true
                }
            } else {
                // Word: light exactly the zones its letters use.
                let zones = Set(text.map(GlyphZoneClass.of))
                ascStrong = zones.contains(.ascender) || zones.contains(.cap)
                descStrong = zones.contains(.descender)
                xStrong = true
            }
        }

        line(Self.ascenderY, color: .systemIndigo, dashed: true, strong: ascStrong)
        line(Self.baselineY - Self.xHeight, color: .systemTeal, dashed: true, strong: xStrong)
        line(Self.baselineY, color: .systemBlue, dashed: false, strong: baseStrong)
        line(Self.descenderY, color: .systemGray, dashed: true, strong: descStrong)
    }
}

final class GuidedCanvasProxy {
    weak var view: GuidedCanvasView?

    var strokes: [PKStroke] { view?.canvas.drawing.strokes ?? [] }

    func clear() { view?.canvas.drawing = PKDrawing() }
}

struct GuidedCanvas: UIViewRepresentable {
    let proxy: GuidedCanvasProxy
    var targetText: String? = nil

    func makeUIView(context: Context) -> GuidedCanvasView {
        let v = GuidedCanvasView()
        v.targetText = targetText
        proxy.view = v
        return v
    }

    func updateUIView(_ view: GuidedCanvasView, context: Context) {
        view.canvas.drawingPolicy = HandwritingSettings.shared.pencilOnly ? .pencilOnly : .default
        if view.targetText != targetText { view.targetText = targetText }
    }
}

// MARK: - Sample preview

struct GlyphPreview: View {
    let glyph: PersonalGlyph
    var selected = false
    var onDelete: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                let strokes = PersonalFontStore.shared.previewInk(for: glyph, in: rect, padding: 6)
                for s in strokes {
                    if s.isDot, let c = s.points.first {
                        let r = s.dotRadius
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                         width: 2 * r, height: 2 * r)),
                                 with: .color(.primary.opacity(0.85)))
                    } else if s.points.count > 1 {
                        var path = Path()
                        path.move(to: s.points[0])
                        for p in s.points.dropFirst() { path.addLine(to: p) }
                        ctx.stroke(path, with: .color(.primary.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    if HandwritingSettings.shared.diagnostics,
                       let start = s.points.first, let finish = s.points.last {
                        ctx.fill(Path(ellipseIn: CGRect(x: start.x - 2, y: start.y - 2,
                                                       width: 4, height: 4)),
                                 with: .color(.green))
                        ctx.fill(Path(ellipseIn: CGRect(x: finish.x - 2, y: finish.y - 2,
                                                       width: 4, height: 4)),
                                 with: .color(.red))
                    }
                }
            }
            .frame(width: 72, height: 56)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red.opacity(0.9))
                }
                .offset(x: 4, y: -4)
            }
        }
    }
}

// MARK: - Calibration screen (SwiftUI)

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    private static let defaultChars = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?':;-()\""
    )

    @State private var proxy = GuidedCanvasProxy()
    @State private var refresh = 0
    @State private var customInput = ""
    @State private var autoAdvance = true
    @State private var justSavedFlash = false
    @State private var saveMessage = ""
    @State private var saveIsWarning = false
    @State private var showTips = false

    @State private var extraChars: [Character] =
        Array(UserDefaults.standard.string(forKey: "penpal.extraChars") ?? "")

    @State private var selectedChar: Character = "a"

    private var chars: [Character] { Self.defaultChars + extraChars }

    private var currentLabel: String { String(selectedChar) }

    private var currentIndex: Int {
        chars.firstIndex(of: selectedChar) ?? 0
    }

    private var samples: Int {
        _ = refresh
        return PersonalFontStore.shared.variantCount(forChar: selectedChar)
    }

    private var currentVariants: [PersonalGlyph] {
        _ = refresh
        return PersonalFontStore.shared.variants(forChar: selectedChar)
    }

    private var trainedCount: Int {
        _ = refresh
        return chars.filter { PersonalFontStore.shared.variantCount(forChar: $0) > 0 }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                unitTrainer
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .navigationTitle("Teach it your hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    HStack(spacing: 6) {
                        Toggle(isOn: $autoAdvance) {
                            Text("Auto-next")
                        }
                        .toggleStyle(.button)
                        .font(.caption)

                        Button {
                            withAnimation { showTips.toggle() }
                        } label: {
                            Image(systemName: showTips ? "info.circle.fill" : "info.circle")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Letters / Words

    /// The rules that most affect echo quality. Users who float letters or
    /// change size between samples get "one word big, one word small" replies.
    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("For the best echo of your hand", systemImage: "lightbulb")
                .font(.caption.weight(.semibold))
            Group {
                Text("• Sit letters on the solid blue line")
                Text("• Letter bodies reach the dashed teal line")
                Text("• Keep the same size across all samples")
                Text("• Write at your natural speed — timing is captured too")
                Text("• Use your real spacing between letters in words")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var unitTrainer: some View {
        VStack(spacing: 10) {
            if showTips { tipsCard }
            // Compact nav: prev · target · next
            HStack(spacing: 12) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title2)
                }
                .disabled(currentIndex <= 0)

                VStack(spacing: 2) {
                    Text(currentLabel)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    Text("\(currentIndex + 1) of \(chars.count) · \(trainedCount) trained")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button { step(1) } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title2)
                }
                .disabled(currentIndex >= chars.count - 1)
            }

                Text("The bright lines are the ones this letter should touch — write naturally between them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

            GuidedCanvas(proxy: proxy,
                         targetText: String(selectedChar))
                .frame(height: GuidedCanvasView.cellHeight)
                .overlay(alignment: .topTrailing) {
                    if justSavedFlash {
                        Text(saveMessage)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(saveIsWarning ? .orange.opacity(0.9)
                                        : .green.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                            .transition(.opacity)
                    }
                }

            // Saved samples live here — review / delete without re-picking chips.
            sampleStrip

            HStack(spacing: 10) {
                Button("Clear") { proxy.clear() }
                    .buttonStyle(.bordered)
                Button {
                    saveCurrent()
                } label: {
                    Label(autoAdvance ? "Save" : "Save sample",
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                if !autoAdvance {
                    Button { step(1) } label: {
                        Label("Next", systemImage: "arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentIndex >= chars.count - 1)
                }

                Spacer(minLength: 0)

                Text("\(samples)/\(PersonalFontStore.maxVariants)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(samples > 0 ? Color.green : Color.secondary)
            }

            HStack(spacing: 8) {
                TextField("Add letters…", text: $customInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Add") { addCustom() }
                    .buttonStyle(.bordered)
                    .disabled(customInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 5)], spacing: 5) {
                    ForEach(Array(chars.enumerated()), id: \.offset) { _, ch in
                        chip(String(ch),
                             selected: selectedChar == ch,
                             trained: PersonalFontStore.shared.variantCount(forChar: ch) > 0) {
                            selectChar(ch)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sampleStrip: some View {
        if currentVariants.isEmpty {
            HStack {
                Image(systemName: "square.dashed")
                    .foregroundStyle(.tertiary)
                Text("Saved samples appear here after you save — so you can check they look right.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(height: 56)
            .padding(.horizontal, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(currentVariants.enumerated()), id: \.offset) { idx, glyph in
                        GlyphPreview(glyph: glyph, selected: idx == currentVariants.count - 1) {
                            deleteVariant(at: idx)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
            }
            .frame(height: 64)
        }
    }

    private func chip(_ label: String, selected: Bool, trained: Bool,
                      action: @escaping () -> Void) -> some View {
        _ = refresh
        return Button(action: action) {
            Text(label)
                .font(.system(.callout, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(selected ? Color.accentColor.opacity(0.28)
                            : trained ? Color.green.opacity(0.18)
                            : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func selectChar(_ ch: Character) {
        selectedChar = ch
        proxy.clear()
        justSavedFlash = false
    }

    private func step(_ delta: Int) {
        let i = (chars.firstIndex(of: selectedChar) ?? 0) + delta
        guard chars.indices.contains(i) else { return }
        selectChar(chars[i])
    }

    /// Jump to the next letter that still needs a sample (wraps around).
    private func advanceAfterSave() {
        guard autoAdvance else { return }
        let start = (chars.firstIndex(of: selectedChar) ?? 0) + 1
        let rotated = Array(chars[start...]) + Array(chars[..<start])
        // Prefer something with zero samples; else just the next character.
        if let next = rotated.first(where: {
            PersonalFontStore.shared.variantCount(forChar: $0) == 0
        }) ?? rotated.first, next != selectedChar {
            selectChar(next)
        }
    }

    // MARK: - Proportion memory (self-consistency)

    /// Running average of each character's RAW written proportions
    /// (pre-normalization). Lets advice compare a new sample against the
    /// user's OWN established style rather than a textbook: consistent
    /// quirks are identity and are never argued with.
    private static let proportionsKey = "penpal.charProportions"

    private func loadProportions() -> [String: [CGFloat]] {
        guard let data = UserDefaults.standard.data(forKey: Self.proportionsKey),
              let dict = try? JSONDecoder().decode([String: [CGFloat]].self, from: data)
        else { return [:] }
        return dict
    }

    private func storeProportion(char: Character, top: CGFloat, bottom: CGFloat) {
        var dict = loadProportions()
        let key = String(char)
        if let old = dict[key], old.count == 3 {
            let n = old[2]
            dict[key] = [(old[0] * n + top) / (n + 1),
                         (old[1] * n + bottom) / (n + 1),
                         n + 1]
        } else {
            dict[key] = [top, bottom, 1]
        }
        if let encoded = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(encoded, forKey: Self.proportionsKey)
        }
    }

    /// Ink extent in x-height units relative to the baseline
    /// (top ≈ 1 at the dashed line; bottom < 0 means below the baseline).
    private func unitExtent(of strokes: [PKStroke]) -> (top: CGFloat, bottom: CGFloat)? {
        let box = strokes.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull else { return nil }
        let base = GuidedCanvasView.baselineY
        let xh = GuidedCanvasView.xHeight
        return ((base - box.minY) / xh, (base - box.maxY) / xh)
    }

    /// Warn (but still save) when a sample fights its zones. First sample of
    /// a letter checks canonical vertical metrics with generous tolerance;
    /// after that, only SELF-consistency is checked — never conformity.
    private func captureAdvice(for strokes: [PKStroke]) -> String? {
        guard let (top, bottom) = unitExtent(of: strokes) else { return nil }

        let ch = selectedChar
        let zone = GlyphZoneClass.of(ch)
        guard zone != .mark else { return nil }

        // Your own established proportions win over canon.
        if let h = loadProportions()[String(ch)], h.count == 3, h[2] >= 1 {
            let dTop = abs(top - h[0])
            let dBottom = abs(bottom - h[1])
            if dTop > max(0.35, abs(h[0]) * 0.35)
                || dBottom > max(0.35, abs(h[1]) * 0.35) {
                return "Saved · sized differently than your earlier “\(ch)” — keep samples consistent"
            }
            return nil
        }

        // First sample: canonical zone check, warn-only, ±generous.
        if bottom > 0.45 {
            return "Saved · floating — sit it on the blue line"
        }
        switch zone {
        case .xHeight:
            if top < 0.55 { return "Saved · small — body up to the dashed teal line" }
            if top > 1.35 { return "Saved · tall — “\(ch)” usually stays at the dashed line" }
        case .ascender, .cap:
            if top < 1.1 { return "Saved · “\(ch)” should reach up near the top line" }
        case .descender:
            if bottom > -0.15 { return "Saved · “\(ch)”'s tail should drop below the blue line" }
            if top < 0.5 { return "Saved · small — body up to the dashed line" }
        case .mark:
            break
        }
        return nil
    }

    private func saveCurrent() {
        let strokes = proxy.strokes
        guard !strokes.isEmpty else {
            saveMessage = "Write a sample first"
            saveIsWarning = true
            withAnimation { justSavedFlash = true }
            return
        }
        let saved = PersonalFontStore.shared.addGlyph(from: strokes, for: selectedChar,
                                                      baselineY: GuidedCanvasView.baselineY,
                                                      xHeight: GuidedCanvasView.xHeight)
        // Punctuation marks are legitimately small/low — no advice for those.
        let isMark = !(selectedChar.isLetter || selectedChar.isNumber)
        let advice = (saved && !isMark) ? captureAdvice(for: strokes) : nil
        // Record raw proportions AFTER advice so the first sample is judged
        // against the canon and later ones against the user's own average.
        if saved, !isMark,
           let (top, bottom) = unitExtent(of: strokes) {
            storeProportion(char: selectedChar, top: top, bottom: bottom)
        }
        saveMessage = saved ? (advice ?? "Saved") : "Too small or duplicate"
        saveIsWarning = !saved || advice != nil
        proxy.clear()
        refresh += 1
        withAnimation { justSavedFlash = true }
        // Linger so the sample strip fills and you can ✕ a bad capture.
        // Advice messages stay longer so they can actually be read.
        let linger = saveIsWarning ? 1.8 : (autoAdvance ? 1.1 : 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
            withAnimation { justSavedFlash = false }
            if saved { advanceAfterSave() }
        }
    }

    private func deleteVariant(at index: Int) {
        PersonalFontStore.shared.removeVariant(forChar: selectedChar, at: index)
        refresh += 1
    }

    private func addCustom() {
        let input = customInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        for ch in input where !chars.contains(ch) && ch != " " {
            extraChars.append(ch)
        }
        UserDefaults.standard.set(String(extraChars), forKey: "penpal.extraChars")
        if let last = input.last(where: { $0 != " " }) { selectChar(last) }
        customInput = ""
    }
}

#Preview {
    CalibrationView()
}
