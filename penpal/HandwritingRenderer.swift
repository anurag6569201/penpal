//
//  HandwritingRenderer.swift
//  penpal
//
//  Animates ink strokes so they appear to be written by an invisible pen:
//  - each stroke reveals via CAShapeLayer strokeEnd
//  - a pen-tip layer travels along the live stroke
//  - human pauses between strokes, per-stroke width variation
//

import UIKit
import PencilKit

final class HandwritingRenderer: UIView {

    var inkColor: UIColor = .systemIndigo
    /// Pen speed in points per second.
    var speed: CGFloat = 320
    var widthScale: CGFloat = 1
    /// How much each stroke's polyline is rounded into a curve before drawing.
    /// 0 = raw captured/synthesized points (straight segments between them);
    /// 1 = fully interpolated Catmull-Rom curve. Removes the "made of little
    /// straight lines / corners" look on sparse glyph outlines (e.g. the round of a d).
    var smoothness: CGFloat = 0
    var isWriting: Bool { generationActive }

    private var inkLayers: [CALayer] = []
    /// Layers created by the write() currently in flight, so an interrupted
    /// write can be replaced wholesale by its instant (static) version.
    private var currentWriteLayers: [CALayer] = []
    /// Called right after stroke `index` finishes animating. When set, the
    /// stroke's animation layer is removed immediately after the call — the
    /// owner is expected to have committed the stroke somewhere permanent
    /// (e.g. into the PKCanvas drawing), making the handoff seamless.
    private var strokeFinishedHandler: ((Int) -> Void)?
    let penDot = CAShapeLayer()
    private let penNib = CAShapeLayer()
    private var generation = 0
    private var generationActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupPen()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupPen()
    }

    private func setupPen() {
        penDot.path = UIBezierPath(ovalIn: CGRect(x: -2, y: -2, width: 4, height: 4)).cgPath
        penDot.fillColor = UIColor.systemIndigo.cgColor
        let nib = UIBezierPath()
        nib.move(to: CGPoint(x: 2, y: -3))
        nib.addLine(to: CGPoint(x: 12, y: -18))
        penNib.path = nib.cgPath
        penNib.strokeColor = UIColor.label.withAlphaComponent(0.6).cgColor
        penNib.lineWidth = 2.5
        penNib.lineCap = .round
        penDot.isHidden = true
        penNib.isHidden = true
        layer.addSublayer(penDot)
        layer.addSublayer(penNib)
    }

    // MARK: - Public

    func write(_ strokes: [InkStroke], baseWidth: CGFloat,
               onStrokeFinished: ((Int) -> Void)? = nil,
               completion: (() -> Void)? = nil) {
        generation += 1
        generationActive = true
        currentWriteLayers.removeAll()
        strokeFinishedHandler = onStrokeFinished
        let gen = generation
        penDot.fillColor = inkColor.cgColor
        penDot.isHidden = false
        // A large animated nib makes the result read like a UI effect. Keep only
        // the subtle contact point while ink is being deposited.
        penNib.isHidden = true
        writeStroke(at: 0, strokes: strokes, baseWidth: baseWidth, gen: gen) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.penDot.isHidden = true
            self.penNib.isHidden = true
            self.generationActive = false
            completion?()
        }
    }

    func cancelWriting() {
        generation += 1
        generationActive = false
        penDot.isHidden = true
        penNib.isHidden = true
        cancelPondering()
        cancelCelebrate()
    }

    func clearInk() {
        cancelWriting()
        inkLayers.forEach { $0.removeFromSuperlayer() }
        inkLayers.removeAll()
        currentWriteLayers.removeAll()
    }

    // MARK: - Pondering (thinking beat before an instant answer)

    var ponderLayers: [CALayer] = []
    var ponderGeneration = 0
    var celebrateLayers: [CALayer] = []
    var celebrateGeneration = 0

    /// Soft "reading this" cue: a faint wash under the ink + a breathing
    /// underline — never a double-drawn stroke overlay on top of PencilKit.
    /// Only for math reads (`=` / boxed ink), never for companion pauses.
    func beginAnalyzing(strokes: [PKStroke]) {
        cancelPondering()
        guard !strokes.isEmpty else { return }
        ponderGeneration += 1
        let start = CACurrentMediaTime() + 0.02

        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !bounds.isNull, bounds.width > 2, bounds.height > 2 else { return }
        let padX = max(8, bounds.height * 0.22)
        let padY = max(4, bounds.height * 0.18)
        let washRect = bounds.insetBy(dx: -padX, dy: -padY)

        let wash = CAShapeLayer()
        wash.name = "analyzeWash"
        wash.path = UIBezierPath(roundedRect: washRect,
                                 cornerRadius: min(14, washRect.height * 0.4)).cgPath
        wash.fillColor = inkColor.withAlphaComponent(0.11).cgColor
        wash.opacity = 0.55
        layer.insertSublayer(wash, below: penDot)
        ponderLayers.append(wash)

        let washPulse = CABasicAnimation(keyPath: "opacity")
        washPulse.fromValue = 0.35
        washPulse.toValue = 0.9
        washPulse.duration = 0.85
        washPulse.autoreverses = true
        washPulse.repeatCount = .infinity
        washPulse.beginTime = start
        washPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        wash.add(washPulse, forKey: "pulse")

        let y = bounds.maxY + max(3, bounds.height * 0.1)
        let underline = CAShapeLayer()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: bounds.minX, y: y))
        line.addLine(to: CGPoint(x: bounds.maxX, y: y))
        underline.path = line.cgPath
        underline.fillColor = nil
        underline.strokeColor = inkColor.withAlphaComponent(0.5).cgColor
        underline.lineWidth = max(1.5, bounds.height * 0.06)
        underline.lineCap = .round
        underline.opacity = 0.7
        layer.insertSublayer(underline, below: penDot)
        ponderLayers.append(underline)

        let linePulse = CABasicAnimation(keyPath: "opacity")
        linePulse.fromValue = 0.35
        linePulse.toValue = 1.0
        linePulse.duration = 0.7
        linePulse.autoreverses = true
        linePulse.repeatCount = .infinity
        linePulse.beginTime = start + 0.08
        linePulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        underline.add(linePulse, forKey: "pulse")

        // Living equals + structure filaments (silent magic).
        attachMathMagic(whileAnalyzing: strokes, at: start)
    }

    func endAnalyzing() {
        cancelPondering()
    }

    // MARK: - Box gesture feedback (boxed problems)

    /// Quick draw-on trace of the box stroke — "I see your box." Registered
    /// with the analyzing layers so endAnalyzing cleans it up automatically.
    func traceBox(_ stroke: PKStroke) {
        guard let (path, width, color) = Self.ghostPath(for: stroke) else { return }
        let trace = CAShapeLayer()
        trace.name = "boxTrace"
        trace.path = path.cgPath
        trace.fillColor = nil
        trace.strokeColor = color.withAlphaComponent(0.55).cgColor
        trace.lineWidth = width + 1.5
        trace.lineCap = .round
        trace.lineJoin = .round
        trace.opacity = 0.9
        layer.insertSublayer(trace, below: penDot)
        ponderLayers.append(trace)

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.35
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        trace.add(draw, forKey: "draw")

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 0.9
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.beginTime = CACurrentMediaTime() + 0.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        trace.add(pulse, forKey: "pulse")
    }

    /// The box did its job — a ghost of the stroke fades away while the real
    /// stroke is removed from the canvas, so the page keeps only actual work.
    func dissolveStrokeGhost(_ stroke: PKStroke) {
        guard let (path, width, color) = Self.ghostPath(for: stroke) else { return }
        let ghost = CAShapeLayer()
        ghost.name = "boxDissolve"
        ghost.path = path.cgPath
        ghost.fillColor = nil
        ghost.strokeColor = color.cgColor
        ghost.lineWidth = width
        ghost.lineCap = .round
        ghost.lineJoin = .round
        ghost.opacity = 0.9
        layer.insertSublayer(ghost, below: penDot)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        fade.duration = 0.55
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        ghost.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            ghost.removeFromSuperlayer()
        }
    }

    /// Polyline of the stroke in drawing coordinates, with its pen width and
    /// ink color — the raw material for trace/dissolve ghosts.
    private static func ghostPath(for stroke: PKStroke) -> (UIBezierPath, CGFloat, UIColor)? {
        var pts: [CGPoint] = []
        for p in stroke.path.interpolatedPoints(by: .distance(3)) {
            pts.append(p.location.applying(stroke.transform))
        }
        guard pts.count > 1 else { return nil }
        let path = UIBezierPath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        let width = max(2, stroke.path.first.map { $0.size.width } ?? 3)
        return (path, width, stroke.ink.color)
    }

    /// Soft ink wash under a freshly written answer — bright for a beat, then
    /// settles away so the result feels newly inked without a highlight box.
    func celebrateAnswer(in rect: CGRect) {
        guard !rect.isNull, rect.width > 2, rect.height > 2 else { return }
        celebrateGeneration += 1
        let gen = celebrateGeneration
        celebrateLayers.forEach { $0.removeFromSuperlayer() }
        celebrateLayers.removeAll()

        let pad = max(4, rect.height * 0.2)
        let wash = CAShapeLayer()
        wash.path = UIBezierPath(roundedRect: rect.insetBy(dx: -pad, dy: -pad * 0.5),
                                 cornerRadius: min(10, rect.height * 0.35)).cgPath
        wash.fillColor = inkColor.withAlphaComponent(0.16).cgColor
        wash.opacity = 0
        layer.insertSublayer(wash, below: penDot)
        celebrateLayers.append(wash)

        let t0 = CACurrentMediaTime()
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = 0.12
        fadeIn.beginTime = t0
        fadeIn.fillMode = .backwards

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.beginTime = t0 + 0.28
        fadeOut.duration = 0.38
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false

        wash.add(fadeIn, forKey: "in")
        wash.add(fadeOut, forKey: "out")
        wash.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.celebrateGeneration == gen else { return }
            wash.removeFromSuperlayer()
            self.celebrateLayers.removeAll { $0 === wash }
        }
    }

    /// Ink-native "working it out" beat: a soft underline draws under the
    /// expression and three pen dots hop at the answer spot — no bounding
    /// box. Then `completion` runs (write the answer).
    func ponder(at point: CGPoint, xHeight: CGFloat, duration: TimeInterval,
                highlighting: CGRect? = nil,
                completion: @escaping () -> Void) {
        cancelPondering()
        ponderGeneration += 1
        let gen = ponderGeneration
        let radius = max(1.8, xHeight * 0.10)
        let gap = radius * 3.6
        let start = CACurrentMediaTime() + 0.04

        if let rect = highlighting, !rect.isNull, rect.width > 4 {
            // Growing underline under the ink — reads as "this is being
            // solved" without a card/box around the writing.
            let y = rect.maxY + max(3, xHeight * 0.12)
            let underline = CAShapeLayer()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            underline.path = path.cgPath
            underline.fillColor = nil
            underline.strokeColor = inkColor.withAlphaComponent(0.55).cgColor
            underline.lineWidth = max(1.6, xHeight * 0.07)
            underline.lineCap = .round
            underline.strokeEnd = 0
            underline.opacity = 0
            layer.insertSublayer(underline, below: penDot)
            ponderLayers.append(underline)

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.18
            fadeIn.beginTime = start
            fadeIn.fillMode = .backwards
            underline.opacity = 1

            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = min(0.55, duration * 0.45)
            draw.beginTime = start
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            draw.fillMode = .forwards
            draw.isRemovedOnCompletion = false
            underline.strokeEnd = 1

            let shimmer = CAKeyframeAnimation(keyPath: "opacity")
            shimmer.values = [1, 0.45, 1, 0.55, 1]
            shimmer.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            shimmer.duration = duration
            shimmer.beginTime = start

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.beginTime = start + duration
            fadeOut.duration = 0.28
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false

            underline.add(fadeIn, forKey: "fadeIn")
            underline.add(draw, forKey: "draw")
            underline.add(shimmer, forKey: "shimmer")
            underline.add(fadeOut, forKey: "fadeOut")
        }

        for i in 0..<3 {
            let dot = CAShapeLayer()
            dot.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius,
                                                   width: 2 * radius,
                                                   height: 2 * radius)).cgPath
            dot.fillColor = inkColor.withAlphaComponent(0.9).cgColor
            dot.position = CGPoint(x: point.x + CGFloat(i) * gap, y: point.y)
            dot.opacity = 0
            layer.addSublayer(dot)
            ponderLayers.append(dot)

            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0, 1, 0.2, 1, 0.2, 1, 0]
            pulse.keyTimes = [0, 0.12, 0.32, 0.5, 0.68, 0.85, 1]
            pulse.duration = duration
            pulse.beginTime = start + Double(i) * 0.12
            pulse.fillMode = .backwards
            dot.add(pulse, forKey: "ponder")

            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = [0, -radius * 2.1, 0, -radius * 1.4, 0, -radius * 0.8, 0]
            hop.keyTimes = [0, 0.18, 0.36, 0.54, 0.72, 0.88, 1]
            hop.duration = duration
            hop.beginTime = pulse.beginTime
            hop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(hop, forKey: "hop")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.35) { [weak self] in
            guard let self, self.ponderGeneration == gen else { return }
            self.cancelPondering()
            completion()
        }
    }

    func cancelPondering() {
        ponderGeneration += 1
        ponderLayers.forEach { $0.removeFromSuperlayer() }
        ponderLayers.removeAll()
    }

    func cancelCelebrate() {
        celebrateGeneration += 1
        celebrateLayers.forEach { $0.removeFromSuperlayer() }
        celebrateLayers.removeAll()
    }

    /// Draws strokes instantly — same layer construction as animated writing
    /// (same smoothing, outlines, alphas), just without the reveal animation
    /// or pen dot. Used to restore saved replies on note load and to complete
    /// an interrupted reply, so the result is visually identical to what the
    /// animation would have produced.
    func drawStatic(_ strokes: [InkStroke], baseWidth: CGFloat) {
        for rawStroke in strokes {
            if rawStroke.isDot, let c = rawStroke.points.first {
                let dot = CAShapeLayer()
                let r = rawStroke.dotRadius
                dot.path = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r,
                                                       width: 2 * r, height: 2 * r)).cgPath
                dot.fillColor = inkColor.cgColor
                layer.insertSublayer(dot, below: penDot)
                inkLayers.append(dot)
                continue
            }
            guard rawStroke.points.count > 1 else { continue }
            let stroke = Self.smoothed(rawStroke, amount: smoothness)

            let centerline = UIBezierPath()
            centerline.move(to: stroke.points[0])
            for i in 1..<stroke.points.count {
                centerline.addLine(to: stroke.points[i])
            }

            if let capturedWidths = stroke.widths, capturedWidths.count == stroke.points.count {
                let widths = capturedWidths.map { $0 * widthScale }
                if let outline = Self.variableWidthOutline(points: stroke.points, widths: widths) {
                    let fill = CAShapeLayer()
                    fill.path = outline
                    // Full opacity — partial alpha meant overlapping ink
                    // (connectors, retraces, ligature joins) compounded into
                    // visibly darker patches while single strokes stayed
                    // lighter, making the tone look uneven letter to letter.
                    fill.fillColor = inkColor.cgColor
                    fill.strokeColor = nil
                    layer.insertSublayer(fill, below: penDot)
                    inkLayers.append(fill)
                    continue
                }
            }
            let shape = CAShapeLayer()
            shape.path = centerline.cgPath
            shape.strokeColor = inkColor.cgColor
            shape.fillColor = nil
            shape.lineWidth = baseWidth
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.insertSublayer(shape, below: penDot)
            inkLayers.append(shape)
        }
    }

    /// Stops the current animated write and removes its layers (the owner is
    /// committing the strokes elsewhere, e.g. into the canvas drawing).
    func abandonCurrentWrite() {
        cancelWriting()
        currentWriteLayers.forEach { $0.removeFromSuperlayer() }
        inkLayers.removeAll { candidate in
            currentWriteLayers.contains { $0 === candidate }
        }
        currentWriteLayers.removeAll()
        strokeFinishedHandler = nil
    }

    /// Stops the current animated write and replaces whatever it had drawn so
    /// far with the complete strokes, drawn instantly and identically.
    func finishCurrentWriteInstantly(_ strokes: [InkStroke], baseWidth: CGFloat) {
        abandonCurrentWrite()
        drawStatic(strokes, baseWidth: baseWidth)
    }

    /// Per-stroke handoff: notify the owner, then (if a handler is installed)
    /// retire the animation layer — the stroke now lives in the canvas.
    private func finishStroke(index: Int, layer: CALayer?, gen: Int) {
        guard generation == gen else { return }
        guard let handler = strokeFinishedHandler else { return }
        handler(index)
        if let layer {
            layer.removeFromSuperlayer()
            inkLayers.removeAll { $0 === layer }
            currentWriteLayers.removeAll { $0 === layer }
        }
    }

    /// Briefly flashes a dashed rectangle + detected line boxes (debug overlay).
    func flashDetection(bounds: CGRect, lines: [DetectedLine], baseline: CGPoint) {
        let group = CALayer()

        let box = CAShapeLayer()
        box.path = UIBezierPath(roundedRect: bounds.insetBy(dx: -8, dy: -8), cornerRadius: 6).cgPath
        box.fillColor = nil
        box.strokeColor = UIColor.systemGray.cgColor
        box.lineWidth = 1
        box.lineDashPattern = [5, 5]
        group.addSublayer(box)

        for line in lines {
            let l = CAShapeLayer()
            l.path = UIBezierPath(rect: line.rect).cgPath
            l.fillColor = nil
            l.strokeColor = UIColor.systemTeal.withAlphaComponent(0.7).cgColor
            l.lineWidth = 0.8
            group.addSublayer(l)
        }

        let cross = CAShapeLayer()
        let cp = UIBezierPath()
        cp.move(to: CGPoint(x: baseline.x - 7, y: baseline.y))
        cp.addLine(to: CGPoint(x: baseline.x + 7, y: baseline.y))
        cp.move(to: CGPoint(x: baseline.x, y: baseline.y - 7))
        cp.addLine(to: CGPoint(x: baseline.x, y: baseline.y + 7))
        cross.path = cp.cgPath
        cross.strokeColor = UIColor.systemRed.withAlphaComponent(0.8).cgColor
        cross.lineWidth = 1.5
        group.addSublayer(cross)

        layer.addSublayer(group)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.2
        fade.duration = 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        group.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            group.removeFromSuperlayer()
        }
    }

    // MARK: - Animation

    private func writeStroke(at index: Int, strokes: [InkStroke], baseWidth: CGFloat,
                             gen: Int, completion: @escaping () -> Void) {
        guard generation == gen else { return }
        guard index < strokes.count else { completion(); return }
        let rawStroke = strokes[index]
        // 320 pt/s is the "natural" reference: captured tempos play back 1:1
        // when the speed slider sits at its default.
        let tempoScale = Double(320 / max(40, speed))

        // Advances to the next stroke. `fromPoint` is where the pen just lifted
        // off; during the inter-stroke pause it glides to the next stroke's start
        // (arcing up like a real hand) instead of teleporting.
        let advance: (CGPoint) -> Void = { [weak self] fromPoint in
            guard let self, self.generation == gen else { return }
            var pause = Double.random(in: 0.03...0.10)
            var nextStart: CGPoint? = nil
            if index + 1 < strokes.count {
                let nxt = strokes[index + 1]
                if let real = nxt.pauseBefore { pause = min(1.2, max(0, real * tempoScale)) }
                if nxt.isWordStart {
                    pause = max(pause, Double(PersonalFontStore.shared.profile.wordPause) * tempoScale)
                }
                nextStart = nxt.points.first
            }
            if let ns = nextStart { self.glidePen(from: fromPoint, to: ns, over: pause) }
            DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
                self?.writeStroke(at: index + 1, strokes: strokes, baseWidth: baseWidth,
                                  gen: gen, completion: completion)
            }
        }

        if rawStroke.isDot, let c = rawStroke.points.first {
            let dot = CAShapeLayer()
            let r = rawStroke.dotRadius
            dot.path = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).cgPath
            dot.fillColor = inkColor.cgColor
            layer.insertSublayer(dot, below: penDot)
            inkLayers.append(dot)
            currentWriteLayers.append(dot)
            movePen(to: c)
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.2
            pop.toValue = 1
            pop.duration = 0.08
            dot.add(pop, forKey: "pop")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.finishStroke(index: index, layer: dot, gen: gen)
                advance(c)
            }
            return
        }

        guard rawStroke.points.count > 1 else {
            finishStroke(index: index, layer: nil, gen: gen)
            advance(penDot.position)
            return
        }

        // Round the raw polyline into a curve so sparse glyph outlines don't
        // read as little straight segments with corners. Everything below draws
        // from this smoothed copy (points, widths and tempo resampled together).
        let stroke = Self.smoothed(rawStroke, amount: smoothness)

        let centerline = UIBezierPath()
        centerline.move(to: stroke.points[0])
        var length: CGFloat = 0
        for i in 1..<stroke.points.count {
            centerline.addLine(to: stroke.points[i])
            length += hypot(stroke.points[i].x - stroke.points[i - 1].x,
                            stroke.points[i].y - stroke.points[i - 1].y)
        }

        let duration: Double
        if let real = stroke.duration {
            duration = max(0.04, real * tempoScale)
        } else {
            duration = max(0.04, Double(length / speed))
        }

        // One timing curve drives BOTH the ink reveal and the pen dot, so the
        // dot always sits exactly at the writing tip. Captured tempo when we
        // have it; otherwise a curvature profile that slows into bends and eases
        // in/out at the ends — the hand-drawing-a-letter feel.
        let keyTimes = Self.travelKeyTimes(stroke)
        let inkLayer: CAShapeLayer

        if let capturedWidths = stroke.widths, capturedWidths.count == stroke.points.count {
            let widths = capturedWidths.map { $0 * widthScale }
            guard let outline = Self.variableWidthOutline(points: stroke.points, widths: widths) else {
                finishStroke(index: index, layer: nil, gen: gen)
                advance(penDot.position)
                return
            }
            // Pressure-varying ink: filled outline revealed by a stroked mask
            // that grows along the centerline.
            let fill = CAShapeLayer()
            fill.path = outline
            fill.fillColor = inkColor.cgColor
            fill.strokeColor = nil

            let mask = CAShapeLayer()
            mask.path = centerline.cgPath
            mask.strokeColor = UIColor.black.cgColor
            mask.fillColor = nil
            mask.lineWidth = (widths.max() ?? baseWidth) + 3
            mask.lineCap = .round
            mask.lineJoin = .round
            fill.mask = mask

            let reveal = Self.revealAnimation(points: stroke.points, keyTimes: keyTimes, duration: duration)
            mask.strokeEnd = 1
            mask.add(reveal, forKey: "reveal")
            inkLayer = fill
        } else {
            let shape = CAShapeLayer()
            shape.path = centerline.cgPath
            shape.strokeColor = inkColor.cgColor
            shape.fillColor = nil
            shape.lineWidth = baseWidth * CGFloat.random(in: 0.8...1.15)
            shape.lineCap = .round
            shape.lineJoin = .round

            let reveal = Self.revealAnimation(points: stroke.points, keyTimes: keyTimes, duration: duration)
            shape.strokeEnd = 1
            shape.add(reveal, forKey: "reveal")
            inkLayer = shape
        }

        layer.insertSublayer(inkLayer, below: penDot)
        inkLayers.append(inkLayer)
        currentWriteLayers.append(inkLayer)

        // The dot traces the exact same points on the exact same clock as the
        // reveal, so it reads as the dot drawing the letter — not sliding along
        // a rail. Dense (smoothed) points make the linear hops hug the curve.
        let travelDot = CAKeyframeAnimation(keyPath: "position")
        travelDot.values = stroke.points.map { NSValue(cgPoint: $0) }
        travelDot.keyTimes = keyTimes
        travelDot.calculationMode = .linear
        travelDot.duration = duration
        penDot.add(travelDot, forKey: "travel")
        penNib.add(travelDot, forKey: "travel")
        let endPoint = stroke.points.last ?? penDot.position
        penDot.position = endPoint
        penNib.position = endPoint

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.finishStroke(index: index, layer: inkLayer, gen: gen)
            advance(endPoint)
        }
    }

    /// Builds a closed outline around a polyline with per-point widths,
    /// producing natural pressure-varying ink. Round caps via end circles.
    static func variableWidthOutline(points: [CGPoint], widths: [CGFloat]) -> CGPath? {
        guard points.count > 1, points.count == widths.count else { return nil }
        var left: [CGPoint] = []
        var right: [CGPoint] = []

        for i in 0..<points.count {
            let prev = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            var tx = next.x - prev.x
            var ty = next.y - prev.y
            let len = hypot(tx, ty)
            if len < 0.001 { tx = 1; ty = 0 } else { tx /= len; ty /= len }
            let edgeTaper: CGFloat = (i == 0 || i == points.count - 1) ? 0.68 : 1
            let half = max(0.45, widths[i] * edgeTaper / 2)
            let nx = -ty, ny = tx
            left.append(CGPoint(x: points[i].x + nx * half, y: points[i].y + ny * half))
            right.append(CGPoint(x: points[i].x - nx * half, y: points[i].y - ny * half))
        }

        let path = CGMutablePath()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()

        if let first = points.first, let fw = widths.first {
            path.addEllipse(in: CGRect(x: first.x - fw / 2, y: first.y - fw / 2, width: fw, height: fw))
        }
        if let last = points.last, let lw = widths.last {
            path.addEllipse(in: CGRect(x: last.x - lw / 2, y: last.y - lw / 2, width: lw, height: lw))
        }
        return path
    }

    /// Resamples a stroke's polyline through a Catmull-Rom spline, blended
    /// toward the original straight-line path by `amount` (0 = unchanged, the
    /// raw points; 1 = fully curved). Widths and per-point times are
    /// interpolated in parallel so pressure and captured tempo are preserved.
    static func smoothed(_ stroke: InkStroke, amount: CGFloat) -> InkStroke {
        let src = stroke.points
        guard amount > 0.001, src.count >= 3 else { return stroke }
        let strength = min(1, max(0, amount))
        let seg = 6   // subdivisions per original segment
        let n = src.count
        let w = stroke.widths
        let t = stroke.pointTimes
        func at(_ i: Int) -> CGPoint { src[min(max(i, 0), n - 1)] }
        func wAt(_ i: Int) -> CGFloat { w?[min(max(i, 0), n - 1)] ?? 0 }
        func tAt(_ i: Int) -> Double { t?[min(max(i, 0), n - 1)] ?? 0 }

        var outP: [CGPoint] = []
        var outW: [CGFloat] = []
        var outT: [Double] = []
        outP.reserveCapacity((n - 1) * seg + 1)

        for i in 0..<(n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            for k in 0..<seg {
                let u = CGFloat(k) / CGFloat(seg)
                let curve = catmullRom(p0, p1, p2, p3, u)
                // Straight-line position between p1 and p2; blending toward the
                // curve by `strength` is what makes smoothness a smooth dial.
                let chordX = p1.x + (p2.x - p1.x) * u
                let chordY = p1.y + (p2.y - p1.y) * u
                outP.append(CGPoint(x: chordX + (curve.x - chordX) * strength,
                                    y: chordY + (curve.y - chordY) * strength))
                outW.append(wAt(i) + (wAt(i + 1) - wAt(i)) * u)
                outT.append(tAt(i) + (tAt(i + 1) - tAt(i)) * Double(u))
            }
        }
        outP.append(at(n - 1)); outW.append(wAt(n - 1)); outT.append(tAt(n - 1))

        var result = stroke
        result.points = outP
        result.widths = (w != nil) ? outW : nil
        result.pointTimes = (t != nil) ? outT : nil
        // These per-point channels aren't used for drawing; drop them so they
        // never look mismatched to a downstream consumer of the resampled copy.
        result.forces = nil
        result.altitudes = nil
        result.azimuths = nil
        return result
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint,
                                   _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        let x = 0.5 * (2 * p1.x + (-p0.x + p2.x) * t
                       + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                       + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
        let y = 0.5 * (2 * p1.y + (-p0.y + p2.y) * t
                       + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                       + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
        return CGPoint(x: x, y: y)
    }

    /// Reveals the ink along its length using a shared timing curve, so the ink
    /// front and the pen dot advance together, point for point.
    private static func revealAnimation(points: [CGPoint], keyTimes: [NSNumber],
                                        duration: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "strokeEnd")
        animation.duration = duration
        guard points.count > 1, points.count == keyTimes.count else {
            animation.values = [0, 1]
            animation.keyTimes = [0, 1]
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            return animation
        }
        var lengths: [CGFloat] = [0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x,
                                                   points[i].y - points[i - 1].y))
        }
        let total = max(0.001, lengths.last ?? 1)
        animation.values = lengths.map { NSNumber(value: Double($0 / total)) }
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        return animation
    }

    /// The per-point time fractions the pen (and ink) follow along a stroke.
    /// Prefers real captured tempo; otherwise a curvature-based profile that
    /// slows into bends and eases in/out at the ends; even spacing as a last resort.
    static func travelKeyTimes(_ stroke: InkStroke) -> [NSNumber] {
        let n = stroke.points.count
        if let captured = normalizedKeyTimes(stroke.pointTimes, count: n) { return captured }
        if let profile = speedProfileKeyTimes(stroke.points) { return profile }
        return (0..<n).map { NSNumber(value: n <= 1 ? 0 : Double($0) / Double(n - 1)) }
    }

    /// Time fractions that make the pen slow through curves and speed on
    /// straights (a hand writes fast in the open, careful round the bends),
    /// with a gentle set-down / lift-off at the two ends.
    private static func speedProfileKeyTimes(_ pts: [CGPoint]) -> [NSNumber]? {
        let n = pts.count
        guard n > 2 else { return nil }
        var segTime: [CGFloat] = []
        for i in 0..<(n - 1) {
            let len = hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y)
            let a = pts[max(0, i - 1)], b = pts[i], c = pts[i + 1], d = pts[min(n - 1, i + 2)]
            let turn = max(turnAngle(a, b, c), turnAngle(b, c, d))   // 0 straight … π sharp
            let speed = max(0.4, 1 - CGFloat(turn / .pi) * 1.2)      // slow into curves
            var t = len / speed
            if i == 0 || i == n - 2 { t *= 1.5 }                     // ease in / out
            segTime.append(t)
        }
        var cum: [CGFloat] = [0]
        for s in segTime { cum.append(cum.last! + s) }
        let total = max(0.0001, cum.last!)
        var out = cum.map { NSNumber(value: Double($0 / total)) }
        out[0] = 0
        out[out.count - 1] = 1
        return out
    }

    /// Unsigned turn angle (radians) between the incoming and outgoing segments
    /// at `b`. 0 = perfectly straight, π = a hairpin.
    private static func turnAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let ux = b.x - a.x, uy = b.y - a.y
        let vx = c.x - b.x, vy = c.y - b.y
        let lu = hypot(ux, uy), lv = hypot(vx, vy)
        guard lu > 0.0001, lv > 0.0001 else { return 0 }
        let cross = ux * vy - uy * vx
        let dot = ux * vx + uy * vy
        return abs(atan2(cross, dot))
    }

    private static func normalizedKeyTimes(_ times: [Double]?, count: Int) -> [NSNumber]? {
        guard let times, times.count == count, count > 1,
              let last = times.last, last > 0 else { return nil }
        var output = times.map { NSNumber(value: min(1, max(0, $0 / last))) }
        output[0] = 0
        output[output.count - 1] = 1
        return output
    }

    private func movePen(to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        penDot.position = point
        penNib.position = point
        CATransaction.commit()
    }

    /// Moves the pen from the end of one stroke to the start of the next along a
    /// small upward arc, briefly fading the contact dot to read as a pen-lift
    /// (hand travelling over the paper) rather than an instant jump.
    private func glidePen(from a: CGPoint, to b: CGPoint, over duration: Double) {
        let dist = hypot(b.x - a.x, b.y - a.y)
        guard duration > 0.05, dist > 1 else { movePen(to: b); return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        penDot.position = b
        penNib.position = b
        CATransaction.commit()

        let lift = min(26, max(6, dist * 0.18))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - lift)
        let arc = UIBezierPath()
        arc.move(to: a)
        arc.addQuadCurve(to: b, controlPoint: mid)

        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = arc.cgPath
        move.duration = duration
        move.calculationMode = .cubicPaced
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.25, 1]
        fade.keyTimes = [0, 0.5, 1]
        fade.duration = duration

        penDot.add(move, forKey: "travel")
        penNib.add(move, forKey: "travel")
        penDot.add(fade, forKey: "lift")
    }
}
