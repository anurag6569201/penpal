//
//  HandwritingRenderer+MathMagic.swift
//  penpal
//
//  The silent "crazy" math beats — living equals, structure filaments, ink
//  morph toward the answer, crumple-on-correction, and ephemeral ghost work.
//  No sound. All overlays; never double-draws PencilKit ink.
//

import UIKit
import PencilKit

extension HandwritingRenderer {

    // MARK: - Analyze extras (called from beginAnalyzing)

    /// Living "=" bars that breathe apart/together, plus constellation filaments
    /// between related symbols (base↔superscript, num↔den).
    func attachMathMagic(whileAnalyzing strokes: [PKStroke], at start: CFTimeInterval) {
        if let bars = MathInkParser.equalsBarRects(in: strokes) {
            addLivingEquals(top: bars.top, bottom: bars.bottom, at: start)
        }
        let links = MathInkParser.structureLinks(in: strokes)
        if !links.isEmpty {
            addFilaments(links, at: start)
        }
    }

    /// Flip living "=" into a soft "≈" when the parse is uncertain.
    func setAnalyzingUncertain(_ uncertain: Bool) {
        guard uncertain else { return }
        // Find the two living-bar layers tagged for equals and nudge the lower
        // one into a slight tilde offset — reads as ≈ without new chrome.
        for layer in ponderLayers {
            guard layer.name == "livingEqualsBottom",
                  let shape = layer as? CAShapeLayer else { continue }
            let shift = CABasicAnimation(keyPath: "transform.translation.x")
            shift.fromValue = 0
            shift.toValue = 5
            shift.duration = 0.55
            shift.autoreverses = true
            shift.repeatCount = .infinity
            shift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(shift, forKey: "approx")

            let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
            tilt.fromValue = 0
            tilt.toValue = -0.12
            tilt.duration = 0.55
            tilt.autoreverses = true
            tilt.repeatCount = .infinity
            shape.add(tilt, forKey: "tilt")
        }
        // Soft amber wash cue on existing analyze wash.
        for layer in ponderLayers where layer.name == "analyzeWash" {
            let tint = CABasicAnimation(keyPath: "opacity")
            tint.fromValue = 0.4
            tint.toValue = 0.95
            tint.duration = 0.65
            tint.autoreverses = true
            tint.repeatCount = .infinity
            layer.add(tint, forKey: "uncertain")
        }
    }

    // MARK: - Morph: ink dust flies toward the answer

    /// Sample points from the expression and send them drifting toward `target`.
    func morphToward(_ target: CGPoint, from strokes: [PKStroke],
                     duration: TimeInterval = 0.7) {
        celebrateGeneration += 1
        let gen = celebrateGeneration
        var samples: [CGPoint] = []
        for stroke in strokes {
            let pts = Array(stroke.path.interpolatedPoints(by: .distance(6)))
            let step = max(1, pts.count / 8)
            for i in stride(from: 0, to: pts.count, by: step) {
                samples.append(pts[i].location)
            }
        }
        if samples.count > 36 {
            samples = stride(from: 0, to: samples.count, by: samples.count / 36)
                .map { samples[$0] }
        }
        let t0 = CACurrentMediaTime()
        let r: CGFloat = 1.6
        for (i, origin) in samples.enumerated() {
            let dot = CAShapeLayer()
            dot.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).cgPath
            dot.fillColor = inkColor.withAlphaComponent(0.75).cgColor
            dot.position = origin
            dot.opacity = 0
            layer.addSublayer(dot)
            celebrateLayers.append(dot)

            let delay = Double(i) * 0.008
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: origin)
            move.toValue = NSValue(cgPoint: CGPoint(
                x: target.x + CGFloat.random(in: -6...6),
                y: target.y + CGFloat.random(in: -5...5)))
            move.duration = duration * 0.85
            move.beginTime = t0 + delay
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0.7, 0]
            fade.keyTimes = [0, 0.15, 0.7, 1]
            fade.duration = duration
            fade.beginTime = t0 + delay
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false

            dot.add(move, forKey: "morph")
            dot.add(fade, forKey: "fade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in
            guard let self, self.celebrateGeneration == gen else { return }
            // Leave celebrateLayers for cancelCelebrate / next celebrate.
        }
    }

    // MARK: - Crumple: wrong reading collapses

    func crumple(strokes: [PKStroke], duration: TimeInterval = 0.45,
                 completion: (() -> Void)? = nil) {
        celebrateGeneration += 1
        let gen = celebrateGeneration
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !bounds.isNull else { completion?(); return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        var samples: [CGPoint] = []
        for stroke in strokes {
            for p in stroke.path.interpolatedPoints(by: .distance(5)) {
                samples.append(p.location)
            }
        }
        if samples.count > 48 {
            samples = stride(from: 0, to: samples.count, by: max(1, samples.count / 48))
                .map { samples[$0] }
        }

        let t0 = CACurrentMediaTime()
        let r: CGFloat = 1.8
        for (i, origin) in samples.enumerated() {
            let dot = CAShapeLayer()
            dot.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).cgPath
            dot.fillColor = inkColor.withAlphaComponent(0.55).cgColor
            dot.position = origin
            layer.addSublayer(dot)
            celebrateLayers.append(dot)

            let dx = origin.x - center.x
            let dy = origin.y - center.y
            // Collapse inward then kick outward like a crumpled ball.
            let mid = CGPoint(x: center.x + dx * 0.15, y: center.y + dy * 0.15)
            let end = CGPoint(x: center.x + dx * 1.6 + CGFloat.random(in: -10...10),
                              y: center.y + dy * 1.6 + CGFloat.random(in: -10...10) + 18)

            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = [NSValue(cgPoint: origin),
                           NSValue(cgPoint: mid),
                           NSValue(cgPoint: end)]
            move.keyTimes = [0, 0.4, 1]
            move.duration = duration
            move.beginTime = t0 + Double(i) * 0.004
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.8
            fade.toValue = 0
            fade.duration = duration
            fade.beginTime = move.beginTime
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.random(in: -2.2...2.2)
            spin.duration = duration
            spin.beginTime = move.beginTime

            dot.add(move, forKey: "crumple")
            dot.add(fade, forKey: "fade")
            dot.add(spin, forKey: "spin")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self, self.celebrateGeneration == gen else {
                completion?()
                return
            }
            self.cancelCelebrate()
            completion?()
        }
    }

    // MARK: - Ghost scratch work

    /// Draws ephemeral handwritten-looking scratch lines (via stroked paths of
    /// laid-out glyphs), holds briefly, fades, then runs `completion`.
    func playGhostSteps(_ stepStrokes: [[InkStroke]], baseWidth: CGFloat,
                        hold: TimeInterval = 0.42,
                        completion: @escaping () -> Void) {
        guard !stepStrokes.isEmpty else { completion(); return }
        // Drop any leftover morph dust so ghost ink is the only overlay.
        celebrateLayers.forEach { $0.removeFromSuperlayer() }
        celebrateLayers.removeAll()
        celebrateGeneration += 1
        let gen = celebrateGeneration
        playGhostStep(at: 0, steps: stepStrokes, baseWidth: baseWidth,
                      hold: hold, gen: gen, completion: completion)
    }

    // MARK: - Private builders

    private func addLivingEquals(top: CGRect, bottom: CGRect, at start: CFTimeInterval) {
        func barLayer(_ rect: CGRect, name: String) -> CAShapeLayer {
            let path = UIBezierPath()
            let y = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            let shape = CAShapeLayer()
            shape.name = name
            shape.path = path.cgPath
            shape.fillColor = nil
            shape.strokeColor = inkColor.withAlphaComponent(0.7).cgColor
            shape.lineWidth = max(2.0, rect.height * 1.1)
            shape.lineCap = .round
            shape.opacity = 0.85
            layer.insertSublayer(shape, below: penDot)
            ponderLayers.append(shape)

            // Breathe apart / together.
            let breathe = CABasicAnimation(keyPath: "transform.translation.y")
            let dir: CGFloat = name.contains("Top") ? -1 : 1
            breathe.fromValue = dir * 1.2
            breathe.toValue = dir * 4.5
            breathe.duration = 0.75
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.beginTime = start
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(breathe, forKey: "breathe")

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45
            pulse.toValue = 1.0
            pulse.duration = 0.75
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = start
            shape.add(pulse, forKey: "pulse")
            return shape
        }
        _ = barLayer(top, name: "livingEqualsTop")
        _ = barLayer(bottom, name: "livingEqualsBottom")
    }

    private func addFilaments(_ links: [(CGPoint, CGPoint)], at start: CFTimeInterval) {
        for (i, link) in links.enumerated() {
            let path = UIBezierPath()
            path.move(to: link.0)
            let mid = CGPoint(x: (link.0.x + link.1.x) / 2 + 3,
                              y: (link.0.y + link.1.y) / 2)
            path.addQuadCurve(to: link.1, controlPoint: mid)
            let filament = CAShapeLayer()
            filament.name = "filament"
            filament.path = path.cgPath
            filament.fillColor = nil
            filament.strokeColor = inkColor.withAlphaComponent(0.35).cgColor
            filament.lineWidth = 1.1
            filament.lineCap = .round
            filament.lineDashPattern = [3, 4]
            filament.strokeEnd = 0
            layer.insertSublayer(filament, below: penDot)
            ponderLayers.append(filament)

            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.45
            draw.beginTime = start + Double(i) * 0.08
            draw.fillMode = .forwards
            draw.isRemovedOnCompletion = false
            filament.strokeEnd = 1

            let shimmer = CABasicAnimation(keyPath: "opacity")
            shimmer.fromValue = 0.25
            shimmer.toValue = 0.75
            shimmer.duration = 0.7
            shimmer.autoreverses = true
            shimmer.repeatCount = .infinity
            shimmer.beginTime = start + 0.2
            filament.add(draw, forKey: "draw")
            filament.add(shimmer, forKey: "shimmer")
        }
    }

    private func playGhostStep(at index: Int, steps: [[InkStroke]],
                               baseWidth: CGFloat, hold: TimeInterval,
                               gen: Int, completion: @escaping () -> Void) {
        guard celebrateGeneration == gen else { return }
        guard index < steps.count else { completion(); return }

        // Clear previous ghost ink layers tagged as ghost.
        for layer in celebrateLayers where layer.name == "ghostInk" {
            layer.removeFromSuperlayer()
        }
        celebrateLayers.removeAll { $0.name == "ghostInk" }

        let strokes = steps[index]
        var made: [CALayer] = []
        for raw in strokes {
            if raw.isDot, let c = raw.points.first {
                let dot = CAShapeLayer()
                let r = raw.dotRadius
                dot.path = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r,
                                                       width: 2 * r, height: 2 * r)).cgPath
                dot.fillColor = inkColor.withAlphaComponent(0.35).cgColor
                dot.name = "ghostInk"
                dot.opacity = 0
                layer.insertSublayer(dot, below: penDot)
                celebrateLayers.append(dot)
                made.append(dot)
                continue
            }
            guard raw.points.count > 1 else { continue }
            let path = UIBezierPath()
            path.move(to: raw.points[0])
            for p in raw.points.dropFirst() { path.addLine(to: p) }
            let shape = CAShapeLayer()
            shape.path = path.cgPath
            shape.fillColor = nil
            shape.strokeColor = inkColor.withAlphaComponent(0.4).cgColor
            shape.lineWidth = baseWidth * 0.9
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.name = "ghostInk"
            shape.opacity = 0
            layer.insertSublayer(shape, below: penDot)
            celebrateLayers.append(shape)
            made.append(shape)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        made.forEach { $0.opacity = 1 }
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.celebrateGeneration == gen else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            made.forEach { $0.opacity = 0 }
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                guard let self, self.celebrateGeneration == gen else { return }
                self.playGhostStep(at: index + 1, steps: steps, baseWidth: baseWidth,
                                   hold: hold, gen: gen, completion: completion)
            }
        }
    }
}
