//
//  CalibrationView.swift
//  penpal
//
//  "Teach it your hand" — train words, letters, joins, math and marks.
//
//  Tabs are ordered by what matters most to mimicry:
//  - Words: the primary source. A designed list where every letter a–z
//    appears in AT LEAST TWO words, so ScaleConsensus gets dense shared-letter
//    cross-constraints and every letterform is captured in real writing flow
//    (people draw a lone "m" big and careful but write it small inside words).
//  - Letters: gap-filler for shapes still missing after Words, plus capitals.
//  - Joins: the most frequent letter pairs — seeds for LigatureEngine and
//    FragmentBank. Connection style matters more to "feels like me" than any
//    single glyph. Pairs already written inside a trained word are credited
//    automatically (cross-tab credit — never ask for the same ink twice).
//  - Math / Marks: digits+operators, punctuation.
//
//  Each unit keeps up to 3 samples for natural variation; write the same one
//  again to add another sample. An always-visible essentials bar shows WHAT
//  KIND of data is still missing, not just how much.
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
    /// The character this sample represents — lets the preview brighten the
    /// guide lines the letter is meant to touch, matching the training canvas.
    var char: Character? = nil
    var selected = false
    var onDelete: (() -> Void)?

    private static let previewPadding: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                // Draw the four-line metric system behind the ink so the saved
                // sample can be read against the lines it will be composed onto.
                if let layout = PersonalFontStore.shared.previewLayout(
                    for: glyph, in: rect, padding: Self.previewPadding) {
                    drawGuideLines(ctx, layout: layout)
                }
                let strokes = PersonalFontStore.shared.previewInk(
                    for: glyph, in: rect, padding: Self.previewPadding)
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
            .frame(width: 76, height: 62)
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

    /// Draws the baseline / x-height / ascender / descender guides on the same
    /// mapping the ink uses, so a saved sample can be verified against the lines
    /// it will be composed onto. The lines a glyph is meant to touch are drawn
    /// stronger (mirrors `GuidedCanvasView`), the rest stay faint for context.
    private func drawGuideLines(_ ctx: GraphicsContext,
                                layout: PersonalFontStore.PreviewLayout) {
        let metrics = HandMetrics.active

        func line(_ y: CGFloat, color: Color, dashed: Bool, strong: Bool) {
            var path = Path()
            path.move(to: CGPoint(x: layout.lineMinX, y: y))
            path.addLine(to: CGPoint(x: layout.lineMaxX, y: y))
            ctx.stroke(path,
                       with: .color(color.opacity(strong ? 0.7 : 0.14)),
                       style: StrokeStyle(lineWidth: strong ? 1.2 : 0.8,
                                          dash: dashed ? [3, 3] : []))
        }

        // Which zones this sample's letter is expected to reach.
        var ascStrong = false, xStrong = true, baseStrong = true, descStrong = false
        if let ch = char {
            switch GlyphZoneClass.of(ch) {
            case .xHeight:  xStrong = true
            case .ascender, .cap: ascStrong = true; xStrong = false
            case .descender: descStrong = true
            case .mark: xStrong = false; baseStrong = true
            }
        }

        line(layout.y(forUnit: metrics.ascender), color: .indigo, dashed: true, strong: ascStrong)
        line(layout.y(forUnit: 1), color: .teal, dashed: true, strong: xStrong)
        line(layout.y(forUnit: 0), color: .blue, dashed: false, strong: baseStrong)
        line(layout.y(forUnit: metrics.descender), color: .gray, dashed: true, strong: descStrong)
    }
}

// MARK: - Calibration screen (SwiftUI)

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss

    private enum TrainMode: String, CaseIterable, Identifiable {
        case words = "Words"
        case letters = "Letters"
        case joins = "Joins"
        case math = "Math"
        case marks = "Marks"
        var id: String { rawValue }
    }

    /// Designed so every letter a–z appears in AT LEAST TWO words. Shared
    /// letters tie the scale of every capture together ("the o in dog must
    /// match the o in wolf"), which keeps ScaleConsensus's joint solve densely
    /// constrained — the fix for "some letters big, some small".
    static let essentialWords: [String] = [
        "the", "and", "was", "her", "dog", "joy", "back",
        "jump", "five", "wolf", "gaze", "hand", "mix", "very",
        "keep", "next", "quiz", "quit", "size", "blow", "nice",
    ]

    /// The most frequent English letter joins, trained as tiny word units so
    /// the entry/exit strokes are real ink. Direct seeds for LigatureEngine
    /// and FragmentBank.
    static let essentialJoins: [String] = [
        "th", "he", "an", "in", "er", "re",
        "on", "at", "nd", "ing", "ll", "oo",
    ]

    private static let letterChars = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )

    /// Digits + operators + common algebra vars for on-device calculator
    /// recognition (no LLM). `× ÷ √` normalize to `* / sqrt` when matching.
    static let mathChars: [Character] = Array("0123456789+-*/=^%!×÷√().,xy")

    /// Punctuation lives in its own tab: marks are exempt from zone advice
    /// and keep their drawn position exactly (GlyphAlign never snaps them).
    static let markChars: [Character] = Array(".,!?':;-()\"")

    @State private var proxy = GuidedCanvasProxy()
    @State private var refresh = 0
    @State private var customInput = ""
    @State private var autoAdvance = true
    @State private var justSavedFlash = false
    @State private var saveMessage = ""
    @State private var saveIsWarning = false
    @State private var showTips = false
    @State private var trainMode: TrainMode = .words

    @State private var extraChars: [Character] =
        Array(UserDefaults.standard.string(forKey: "penpal.extraChars") ?? "")
    @State private var extraWords: [String] =
        (UserDefaults.standard.string(forKey: "penpal.extraWords") ?? "")
            .split(separator: " ").map(String.init)

    /// The unit being trained — a single character (count == 1) or a whole
    /// word/join. One selection model for every tab.
    @State private var selectedTarget: String = "the"

    private var isWordTarget: Bool { selectedTarget.count > 1 }

    private func targets(for mode: TrainMode) -> [String] {
        switch mode {
        case .words: return Self.essentialWords + extraWords
        case .letters: return (Self.letterChars + extraChars).map(String.init)
        case .joins: return Self.essentialJoins
        case .math: return Self.mathChars.map(String.init)
        case .marks: return Self.markChars.map(String.init)
        }
    }

    private var targets: [String] { targets(for: trainMode) }

    private var currentIndex: Int {
        targets.firstIndex(of: selectedTarget) ?? 0
    }

    /// Whether a target has at least one sample — with CROSS-TAB CREDIT: a
    /// join like "th" counts as trained if captured directly OR inside any
    /// trained word ("the"), because LigatureEngine and FragmentBank already
    /// harvested it from that word. Never ask for the same ink twice.
    private func isTrained(_ target: String) -> Bool {
        if target.count > 1 {
            if PersonalFontStore.shared.variantCount(forWord: target) > 0 { return true }
            if Self.essentialJoins.contains(target) {
                return PersonalFontStore.shared.trainedWordList
                    .contains { $0.contains(target) }
            }
            return false
        }
        guard let ch = target.first else { return false }
        return PersonalFontStore.shared.variantCount(forChar: ch) > 0
    }

    private var samples: Int {
        _ = refresh
        if isWordTarget {
            return PersonalFontStore.shared.variantCount(forWord: selectedTarget)
        }
        guard let ch = selectedTarget.first else { return 0 }
        return PersonalFontStore.shared.variantCount(forChar: ch)
    }

    private var currentVariants: [PersonalGlyph] {
        _ = refresh
        if isWordTarget {
            return PersonalFontStore.shared.variants(forWord: selectedTarget)
        }
        guard let ch = selectedTarget.first else { return [] }
        return PersonalFontStore.shared.variants(forChar: ch)
    }

    private var trainedCount: Int {
        _ = refresh
        return targets.filter { isTrained($0) }.count
    }

    /// Essential coverage per tab — the finish line. Letters counts lowercase
    /// a–z only (capitals are polish); Words and Joins count the designed
    /// lists, not user extras.
    private func essentialProgress(for mode: TrainMode) -> (done: Int, total: Int) {
        _ = refresh
        switch mode {
        case .words:
            return (Self.essentialWords.filter { isTrained($0) }.count,
                    Self.essentialWords.count)
        case .joins:
            return (Self.essentialJoins.filter { isTrained($0) }.count,
                    Self.essentialJoins.count)
        case .letters:
            let lower = "abcdefghijklmnopqrstuvwxyz"
            return (lower.filter {
                PersonalFontStore.shared.variantCount(forChar: $0) > 0
            }.count, 26)
        case .math:
            return (Self.mathChars.filter {
                PersonalFontStore.shared.variantCount(forChar: $0) > 0
            }.count, Self.mathChars.count)
        case .marks:
            return (Self.markChars.filter {
                PersonalFontStore.shared.variantCount(forChar: $0) > 0
            }.count, Self.markChars.count)
        }
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
                Text("• Train Words first — they teach your sizing and joins together")
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

            Picker("Train", selection: $trainMode) {
                ForEach(TrainMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: trainMode) { _, _ in
                // Land on the first target still missing a sample.
                let t = targets
                if let first = t.first(where: { !isTrained($0) }) ?? t.first {
                    selectTarget(first)
                }
            }

            essentialsBar

            if let caption = modeCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Compact nav: prev · target · next
            HStack(spacing: 12) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title2)
                }
                .disabled(currentIndex <= 0)

                VStack(spacing: 2) {
                    Text(selectedTarget)
                        .font(.system(size: isWordTarget ? 34 : 44,
                                      weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    Text("\(currentIndex + 1) of \(targets.count) · \(trainedCount) trained")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button { step(1) } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title2)
                }
                .disabled(currentIndex >= targets.count - 1)
            }

                Text("The bright lines are the ones this \(isWordTarget ? "word" : "letter") should touch — write naturally between them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

            GuidedCanvas(proxy: proxy,
                         targetText: selectedTarget)
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
                    .disabled(currentIndex >= targets.count - 1)
                }

                Spacer(minLength: 0)

                Text("\(samples)/\(PersonalFontStore.maxVariants)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(samples > 0 ? Color.green : Color.secondary)
            }

            if trainMode == .letters || trainMode == .words {
                HStack(spacing: 8) {
                    TextField(trainMode == .words
                              ? "Add words — your name, words you write a lot…"
                              : "Add letters…",
                              text: $customInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Add") { addCustom() }
                        .buttonStyle(.bordered)
                        .disabled(customInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(
                    minimum: (trainMode == .words || trainMode == .joins) ? 58 : 36),
                    spacing: 5)], spacing: 5) {
                    ForEach(Array(targets.enumerated()), id: \.offset) { _, t in
                        chip(t,
                             selected: selectedTarget == t,
                             trained: isTrained(t)) {
                            selectTarget(t)
                        }
                    }
                }
            }
        }
    }

    /// Always-visible finish line: WHAT KIND of data is still missing, not
    /// just how much. Words + Joins + Letters are the essentials that make
    /// replies feel like the user; Math and Marks are per-use-case extras.
    private var essentialsBar: some View {
        HStack(spacing: 12) {
            ForEach([TrainMode.words, .joins, .letters], id: \.self) { mode in
                let p = essentialProgress(for: mode)
                let complete = p.done >= p.total
                Button { trainMode = mode } label: {
                    HStack(spacing: 3) {
                        Image(systemName: complete ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption2)
                        Text("\(mode.rawValue) \(p.done)/\(p.total)")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(complete ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var modeCaption: String? {
        switch trainMode {
        case .words:
            return "The heart of your hand — whole words as real connected ink. Every letter a–z appears in at least two of these, so sizing is learned from how you actually write in flow."
        case .letters:
            return "Gap-filler for letters still missing after Words, plus capitals. Words teach flow; these teach shape."
        case .joins:
            return "Letter pairs the way you join them. Connections matter more to \u{201C}feels like me\u{201D} than any single letter. Pairs already inside a trained word are credited automatically."
        case .math:
            return "Train digits and math signs. Powers: train \"^\" as a caret, or write exponents raised (x²) — Penpal detects superscripts by layout. Fixing the Solve chip also trains from your ink."
        case .marks:
            return "Punctuation, written where it naturally sits — a comma hangs low, an apostrophe floats high. Position is kept exactly as you draw it."
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
                        GlyphPreview(glyph: glyph,
                                     char: isWordTarget ? nil : selectedTarget.first,
                                     selected: idx == currentVariants.count - 1) {
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

    private func selectTarget(_ t: String) {
        selectedTarget = t
        proxy.clear()
        justSavedFlash = false
    }

    private func step(_ delta: Int) {
        let i = (targets.firstIndex(of: selectedTarget) ?? 0) + delta
        guard targets.indices.contains(i) else { return }
        selectTarget(targets[i])
    }

    /// Jump to the next target that still needs a sample (wraps around).
    private func advanceAfterSave() {
        guard autoAdvance else { return }
        let start = (targets.firstIndex(of: selectedTarget) ?? 0) + 1
        let rotated = Array(targets[start...]) + Array(targets[..<start])
        // Prefer something with zero samples; else just the next target.
        if let next = rotated.first(where: { !isTrained($0) }) ?? rotated.first,
           next != selectedTarget {
            selectTarget(next)
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
    /// a letter checks vertical metrics with generous tolerance — against the
    /// user's own learned HandMetrics once words have personalized them;
    /// after that, only SELF-consistency is checked — never conformity.
    private func charAdvice(for strokes: [PKStroke], ch: Character) -> String? {
        guard let (top, bottom) = unitExtent(of: strokes) else { return nil }

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

        // First sample: zone check, warn-only, ±generous. Thresholds follow
        // the user's LEARNED line ratios (HandMetrics starts at classic
        // proportions and personalizes as words are trained), so this
        // enforces THEIR hand — not a font's.
        let m = HandMetrics.active
        if bottom > 0.45 {
            return "Saved · floating — sit it on the blue line"
        }
        switch zone {
        case .xHeight:
            if top < 0.55 { return "Saved · small — body up to the dashed teal line" }
            if top > 1.35 { return "Saved · tall — “\(ch)” usually stays at the dashed line" }
        case .ascender, .cap:
            if top < max(1.05, m.ascender * 0.66) {
                return "Saved · “\(ch)” should reach up near the top line"
            }
        case .descender:
            if bottom > min(-0.15, m.descender * 0.3) {
                return "Saved · “\(ch)”'s tail should drop below the blue line"
            }
            if top < 0.5 { return "Saved · small — body up to the dashed line" }
        case .mark:
            break
        }
        return nil
    }

    /// Word-aware zone check. Expectations come from which zones the word's
    /// letters actually use, targets from the user's own learned HandMetrics.
    /// Warn-only — the capture is already saved and can be ✕'d in the strip.
    private func wordAdvice(for strokes: [PKStroke], word: String) -> String? {
        guard let (top, bottom) = unitExtent(of: strokes) else { return nil }
        let m = HandMetrics.active
        let zones = Set(word.map { GlyphZoneClass.of($0) })

        if bottom > 0.45 {
            return "Saved · floating — sit the word on the blue line"
        }
        if zones.contains(.ascender) || zones.contains(.cap) {
            if top < m.ascender * 0.72 {
                return "Saved · tall letters should reach near the top line"
            }
        } else if top > 1.45 {
            return "Saved · big — letter bodies stop at the dashed teal line"
        } else if top < 0.5 {
            return "Saved · small — letter bodies up to the dashed teal line"
        }
        if zones.contains(.descender), bottom > m.descender * 0.3 {
            return "Saved · tails (g j p q y) should drop below the blue line"
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
        let saved: Bool
        var advice: String?
        if isWordTarget {
            // Words and joins are stored as whole units — addWord also feeds
            // the profile, LigatureEngine, FragmentBank and StrokeVAE.
            saved = PersonalFontStore.shared.addWord(
                from: strokes, for: selectedTarget,
                baselineY: GuidedCanvasView.baselineY,
                xHeight: GuidedCanvasView.xHeight)
            if saved { advice = wordAdvice(for: strokes, word: selectedTarget) }
        } else if let ch = selectedTarget.first {
            saved = PersonalFontStore.shared.addGlyph(
                from: strokes, for: ch,
                baselineY: GuidedCanvasView.baselineY,
                xHeight: GuidedCanvasView.xHeight)
            // Punctuation marks are legitimately small/low — no advice.
            let isMark = !(ch.isLetter || ch.isNumber)
            if saved, !isMark {
                advice = charAdvice(for: strokes, ch: ch)
                // Record raw proportions AFTER advice so the first sample is
                // judged against the canon and later ones against the user's
                // own average.
                if let (top, bottom) = unitExtent(of: strokes) {
                    storeProportion(char: ch, top: top, bottom: bottom)
                }
            }
        } else {
            saved = false
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
        if isWordTarget {
            PersonalFontStore.shared.removeVariant(forWord: selectedTarget, at: index)
        } else if let ch = selectedTarget.first {
            PersonalFontStore.shared.removeVariant(forChar: ch, at: index)
        }
        refresh += 1
    }

    private func addCustom() {
        let input = customInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        switch trainMode {
        case .words:
            let existing = Set(targets)
            let added = input.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count > 1 && !existing.contains($0) }
            guard !added.isEmpty else { customInput = ""; return }
            extraWords.append(contentsOf: added)
            UserDefaults.standard.set(extraWords.joined(separator: " "),
                                      forKey: "penpal.extraWords")
            if let last = added.last { selectTarget(last) }
        default:
            for ch in input where !targets.contains(String(ch)) && ch != " " {
                extraChars.append(ch)
            }
            UserDefaults.standard.set(String(extraChars), forKey: "penpal.extraChars")
            if let last = input.last(where: { $0 != " " }) { selectTarget(String(last)) }
        }
        customInput = ""
    }
}

#Preview {
    CalibrationView()
}
