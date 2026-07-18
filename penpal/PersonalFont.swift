//
//  PersonalFont.swift
//  penpal
//
//  Your handwriting as a font — v2.
//
//  Units are stored at two levels:
//  - characters: composed letter by letter (fallback)
//  - words: whole words captured as one unit — effectively an "echo" of your
//    real connected writing, which is why they look perfect. Works for any
//    language/script since no segmentation is needed.
//
//  Each unit keeps up to 3 variants (natural variation instead of fake jitter)
//  and per-point pen widths (Apple Pencil pressure), so replies render with
//  the same line quality as your real ink.
//
//  Unit space: baseline y = 0, x-height y = 1, y grows UP.
//

import PencilKit

struct PersonalGlyph: Codable {
    /// Ink width in x-height units (spacing added by composer).
    var width: CGFloat
    /// Strokes in unit space. Single-point strokes are dots.
    var strokes: [[CGPoint]]
    /// Optional per-point pen widths, normalized by the training x-height.
    var widths: [[CGFloat]]?
    /// Real writing time per stroke, seconds (as captured).
    var durations: [Double]?
    /// Real pen-lift pause before each stroke, seconds (first is 0).
    var gaps: [Double]?
    /// x-height in points at capture time; used to scale tempo for other sizes.
    var refSize: CGFloat?
    /// Per-point time offsets from the beginning of each stroke.
    var pointTimes: [[Double]]? = nil
    /// Raw Pencil force, altitude and azimuth when available.
    var forces: [[CGFloat]]? = nil
    var altitudes: [[CGFloat]]? = nil
    var azimuths: [[CGFloat]]? = nil
    /// Capture provenance and quality are optional for v1/v2 data migration.
    var inputSource: String? = nil
    var quality: CGFloat? = nil
    /// Legacy marker from the removed paragraph trainer; variants carrying it
    /// were low-quality auto-segmented captures and are purged at load.
    var paragraphCaptureID: String? = nil
}

/// Global traits of the hand, learned from word samples.
struct HandwritingProfile: Codable {
    /// 0 = printed (pen lifts per letter), 1 = fully cursive (connected).
    var connectedness: CGFloat = 0.3
    /// Gap between words, in x-heights.
    var wordGapUnits: CGFloat = 0.55
    var slant: CGFloat = 0
    var wordPause: CGFloat = 0.18
    var accelerationCV: CGFloat = 0.2
    var samples: Int = 0

    mutating func absorb(connectedness c: CGFloat?, wordGapUnits g: CGFloat?,
                         slant s: CGFloat? = nil, wordPause wp: CGFloat? = nil,
                         accelerationCV acv: CGFloat? = nil) {
        let n = CGFloat(samples)
        if let c { connectedness = (connectedness * n + c) / (n + 1) }
        if let g { wordGapUnits = min(1.2, max(0.3, (wordGapUnits * n + g) / (n + 1))) }
        if let s { slant = min(1.2, max(-1.2, (slant * n + s) / (n + 1))) }
        if let wp { wordPause = min(1.2, max(0.06, (wordPause * n + wp) / (n + 1))) }
        if let acv { accelerationCV = min(2, max(0, (accelerationCV * n + acv) / (n + 1))) }
        samples += 1
    }
}

private struct PersonalFontData: Codable {
    var schemaVersion: Int? = 4
    var glyphs: [String: [PersonalGlyph]] = [:]
    var words: [String: [PersonalGlyph]] = [:]
    var profile: HandwritingProfile?
}

final class PersonalFontStore {

    static let shared = PersonalFontStore()
    /// Three good samples capture natural variation without making calibration
    /// repetitive or letting stale shapes dominate synthesis.
    static let maxVariants = 3

    private var data = PersonalFontData()

    var trainedChars: Set<String> { Set(data.glyphs.keys) }
    var trainedWords: Set<String> { Set(data.words.keys) }

    func variantCount(forChar ch: Character) -> Int { data.glyphs[String(ch)]?.count ?? 0 }
    func variantCount(forWord w: String) -> Int { data.words[normalize(w)]?.count ?? 0 }

    private func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("personal_font.json")
    }

    init() { load() }

    // MARK: - Capture

    /// Converts drawn strokes in a calibration cell to a normalized glyph.
    private func makeGlyph(from strokes: [PKStroke],
                           baselineY: CGFloat, xHeight: CGFloat) -> PersonalGlyph? {
        func extent(of pts: [CGPoint]) -> (min: CGPoint, max: CGPoint)? {
            guard let first = pts.first else { return nil }
            var lo = first, hi = first
            for p in pts {
                lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
                hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
            }
            return (lo, hi)
        }

        var raw: [[CGPoint]] = []
        var rawWidths: [[CGFloat]] = []
        var rawTimes: [[Double]] = []
        var rawForces: [[CGFloat]] = []
        var rawAltitudes: [[CGFloat]] = []
        var rawAzimuths: [[CGFloat]] = []
        var durations: [Double] = []
        var gaps: [Double] = []
        var previousEnd: Date?
        for stroke in strokes {
            var pts: [CGPoint] = []
            var ws: [CGFloat] = []
            var ts: [Double] = []
            var fs: [CGFloat] = []
            var alts: [CGFloat] = []
            var azs: [CGFloat] = []
            var lastOffset: TimeInterval = 0
            for point in stroke.path.interpolatedPoints(by: .distance(1)) {
                if let last = pts.last {
                    let distance = hypot(point.location.x - last.x, point.location.y - last.y)
                    let elapsed = point.timeOffset - (ts.last ?? 0)
                    // Keep dense corner/timing samples, but discard sensor duplicates.
                    if distance < 0.45 && elapsed < 0.008 { continue }
                }
                pts.append(point.location)
                ws.append(point.size.width)
                ts.append(point.timeOffset)
                fs.append(point.force)
                alts.append(point.altitude)
                azs.append(point.azimuth)
                lastOffset = max(lastOffset, point.timeOffset)
            }
            if !pts.isEmpty {
                raw.append(pts)
                rawWidths.append(ws)
                rawTimes.append(ts)
                rawForces.append(fs)
                rawAltitudes.append(alts)
                rawAzimuths.append(azs)
                durations.append(lastOffset)
                let started = stroke.path.creationDate
                gaps.append(previousEnd.map { min(2, max(0, started.timeIntervalSince($0))) } ?? 0)
                previousEnd = started.addingTimeInterval(lastOffset)
            }
        }
        guard let total = extent(of: raw.flatMap { $0 }),
              total.max.x - total.min.x > 1 || total.max.y - total.min.y > 1 else { return nil }

        let originX = total.min.x
        var unitStrokes: [[CGPoint]] = []
        var unitWidths: [[CGFloat]] = []
        var pointTimes: [[Double]] = []
        var forces: [[CGFloat]] = []
        var altitudes: [[CGFloat]] = []
        var azimuths: [[CGFloat]] = []
        for (i, pts) in raw.enumerated() {
            guard let e = extent(of: pts) else { continue }
            let diag = hypot(e.max.x - e.min.x, e.max.y - e.min.y)
            if diag < xHeight * 0.14 {
                let c = CGPoint(x: (e.min.x + e.max.x) / 2, y: (e.min.y + e.max.y) / 2)
                unitStrokes.append([CGPoint(x: (c.x - originX) / xHeight,
                                            y: (baselineY - c.y) / xHeight)])
                unitWidths.append([(rawWidths[i].max() ?? 3) / xHeight])
                pointTimes.append([rawTimes[i].last ?? 0])
                forces.append([rawForces[i].max() ?? 0])
                altitudes.append([rawAltitudes[i].last ?? 0])
                azimuths.append([rawAzimuths[i].last ?? 0])
            } else {
                unitStrokes.append(pts.map {
                    CGPoint(x: ($0.x - originX) / xHeight,
                            y: (baselineY - $0.y) / xHeight)
                })
                unitWidths.append(rawWidths[i].map { $0 / xHeight })
                pointTimes.append(rawTimes[i])
                forces.append(rawForces[i])
                altitudes.append(rawAltitudes[i])
                azimuths.append(rawAzimuths[i])
            }
        }

        let width = (total.max.x - total.min.x) / xHeight
        let pointCount = unitStrokes.reduce(0) { $0 + $1.count }
        let quality = min(1, max(0, CGFloat(pointCount) / 28))
            * min(1, max(0.25, width / 0.45))
        let source = forces.flatMap { $0 }.contains(where: { $0 > 0.01 }) ? "pencil" : "touch"
        let glyph = PersonalGlyph(width: width, strokes: unitStrokes,
                                  widths: unitWidths, durations: durations,
                                  gaps: gaps, refSize: xHeight,
                                  pointTimes: pointTimes, forces: forces,
                                  altitudes: altitudes, azimuths: azimuths,
                                  inputSource: source, quality: quality)
        return Self.isValid(glyph) ? glyph : nil
    }

    static func isValid(_ glyph: PersonalGlyph) -> Bool {
        let points = glyph.strokes.flatMap { $0 }
        guard points.count >= 2, glyph.width.isFinite, glyph.width > 0.03, glyph.width < 40 else {
            return false
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite
            && abs($0.x) < 80 && abs($0.y) < 20 }) else { return false }
        if let times = glyph.pointTimes {
            for row in times {
                guard row.allSatisfy(\.isFinite),
                      zip(row, row.dropFirst()).allSatisfy({ $0 <= $1 }) else { return false }
            }
        }
        return true
    }

    /// Capture + auto-align so floating/tilted training still sits on baseline.
    private func makeAlignedGlyph(from strokes: [PKStroke],
                                  baselineY: CGFloat, xHeight: CGFloat,
                                  char: Character? = nil) -> PersonalGlyph? {
        guard let raw = makeGlyph(from: strokes, baselineY: baselineY, xHeight: xHeight) else {
            return nil
        }
        return GlyphAlign.normalize(raw, forChar: char)
    }

    /// Adds a variant for a character (keeps the newest `maxVariants`).
    @discardableResult
    func addGlyph(from strokes: [PKStroke], for ch: Character,
                  baselineY: CGFloat, xHeight: CGFloat) -> Bool {
        guard let g = makeAlignedGlyph(from: strokes, baselineY: baselineY,
                                       xHeight: xHeight, char: ch) else { return false }
        var list = data.glyphs[String(ch)] ?? []
        guard !list.contains(where: { Self.shapeDistance($0, g) < 0.018 }) else { return false }
        list.append(g)
        if list.count > Self.maxVariants { list.removeFirst(list.count - Self.maxVariants) }
        data.glyphs[String(ch)] = list
        StyleRL.shared.observeReal(g, letterCount: 1)
        OpticalKern.invalidateAll()
        GlyphPDM.shared.invalidateAll()
        invalidateConsensus()
        save()
        return true
    }

    /// Best trained character for live ink among `alphabet`.
    /// Uses the same unit-space distance as de-duplication at capture time.
    /// `unit` is a local symbol height in points (e.g. MathInkParser's symbolUnit).
    func matchChar(from strokes: [PKStroke], among alphabet: [Character],
                   unit: CGFloat,
                   maxDistance: CGFloat = 0.28) -> (char: Character, distance: CGFloat)? {
        guard unit > 2, !strokes.isEmpty, !alphabet.isEmpty else { return nil }
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !bounds.isNull, bounds.width > 0.5 || bounds.height > 0.5 else { return nil }
        // Digits/ops in the trainer span ~cap height ≈ 2× x-height.
        let xHeight = max(unit * 0.55, bounds.height * 0.5, 4)
        let baselineY = bounds.maxY
        guard let probe = makeAlignedGlyph(from: strokes, baselineY: baselineY,
                                           xHeight: xHeight) else { return nil }

        var best: (Character, CGFloat)?
        for ch in alphabet {
            guard let variants = data.glyphs[String(ch)], !variants.isEmpty else { continue }
            // Prefer similar stroke counts — a 1-stroke "1" shouldn't win as "8".
            let strokeCount = probe.strokes.count
            for variant in variants {
                let strokePenalty: CGFloat = abs(variant.strokes.count - strokeCount) > 1
                    ? 0.12 : (variant.strokes.count == strokeCount ? 0 : 0.04)
                let d = Self.shapeDistance(variant, probe) + strokePenalty
                if let current = best {
                    if d < current.1 { best = (ch, d) }
                } else {
                    best = (ch, d)
                }
            }
        }
        guard let best, best.1 <= maxDistance else { return nil }
        return (best.0, best.1)
    }

    /// Whether any character in `alphabet` has at least one trained sample.
    func hasTrained(anyOf alphabet: [Character]) -> Bool {
        alphabet.contains { variantCount(forChar: $0) > 0 }
    }

    /// Adds a variant for a whole word (any language/script).
    @discardableResult
    func addWord(from strokes: [PKStroke], for word: String,
                 baselineY: CGFloat, xHeight: CGFloat) -> Bool {
        let key = normalize(word)
        guard !key.isEmpty,
              let g = makeAlignedGlyph(from: strokes, baselineY: baselineY,
                                       xHeight: xHeight) else { return false }
        // LINE TRUST: the capture was made against visible guide lines and is
        // already normalized by them — that IS the user's size for this word.
        // Cross-calibrating against corpus averages resized good captures.
        var list = data.words[key] ?? []
        guard !list.contains(where: { Self.shapeDistance($0, g) < 0.012 }) else { return false }
        list.append(g)
        if list.count > Self.maxVariants { list.removeFirst(list.count - Self.maxVariants) }
        data.words[key] = list

        // Learn connectedness: 1 stroke for a 5-letter word = cursive,
        // 1+ strokes per letter = printed.
        let letters = CGFloat(key.count)
        if letters >= 2 {
            let spl = CGFloat(g.strokes.count) / letters
            let c = min(1, max(0, 1.5 / max(spl, 0.3) - 0.5))
            var p = data.profile ?? HandwritingProfile()
            let features = HandFeatures.extract(from: g, letterCount: key.count)
            p.absorb(connectedness: c, wordGapUnits: nil,
                     slant: features.slantMean, wordPause: features.wordPauseMean,
                     accelerationCV: features.accelerationCV)
            data.profile = p
        }
        StyleRL.shared.observeReal(g, letterCount: max(1, key.count))
        StrokeVAE.shared.observe(word: key, glyph: g)
        FragmentBank.shared.harvest(word: key, glyph: g)
        LigatureEngine.shared.observe(word: key, glyph: g)
        vaeCache.removeValue(forKey: key)
        invalidateConsensus()
        save()
        return true
    }

    private func rebuildDerivedModels() {
        var profile = HandwritingProfile()
        for (word, variants) in data.words {
            for glyph in variants {
                let letters = max(1, CGFloat(word.count))
                let strokesPerLetter = CGFloat(glyph.strokes.count) / letters
                let connectedness = min(1, max(0, 1.5 / max(strokesPerLetter, 0.3) - 0.5))
                let features = HandFeatures.extract(from: glyph, letterCount: word.count)
                profile.absorb(connectedness: connectedness, wordGapUnits: nil,
                               slant: features.slantMean,
                               wordPause: features.wordPauseMean,
                               accelerationCV: features.accelerationCV)
            }
        }
        data.profile = profile
        FragmentBank.shared.rebuild(words: data.words)
        LigatureEngine.shared.rebuild(words: data.words)
        StrokeVAE.shared.rebuild(words: data.words)
        let samples = data.glyphs.values.flatMap { $0 }.map { ($0, 1) }
            + data.words.flatMap { key, variants in variants.map { ($0, max(1, key.count)) } }
        StyleRL.shared.rebuild(samples: samples)
        vaeCache.removeAll()
    }

    private static func shapeDistance(_ a: PersonalGlyph, _ b: PersonalGlyph) -> CGFloat {
        guard abs(a.width - b.width) < 0.18 else { return 1 }
        let ap = a.strokes.flatMap { $0 }
        let bp = b.strokes.flatMap { $0 }
        guard !ap.isEmpty, !bp.isEmpty else { return 1 }
        let n = min(24, min(ap.count, bp.count))
        guard n > 1 else { return 1 }
        var total: CGFloat = 0
        for i in 0..<n {
            let ai = i * (ap.count - 1) / (n - 1)
            let bi = i * (bp.count - 1) / (n - 1)
            total += hypot(ap[ai].x - bp[bi].x, ap[ai].y - bp[bi].y)
        }
        return total / CGFloat(n)
    }

    // MARK: - Scale consensus

    private var cachedMeans: [Character: CGFloat]?
    private var cachedIsolatedGain: CGFloat?

    /// Consensus body height per letter class across all word captures.
    var consensusMeans: [Character: CGFloat] {
        if let cachedMeans { return cachedMeans }
        let m = ScaleConsensus.classMeans(words: data.words)
        cachedMeans = m
        return m
    }

    /// Isolated char training runs bigger than the same letters in word flow.
    /// Words composed from the char bank are scaled by this so both sources
    /// sit at one visual size.
    var isolatedGain: CGFloat {
        if let cachedIsolatedGain { return cachedIsolatedGain }
        let g = ScaleConsensus.isolatedGain(means: consensusMeans, chars: data.glyphs)
        cachedIsolatedGain = g
        return g
    }

    private func invalidateConsensus() {
        cachedMeans = nil
        cachedIsolatedGain = nil
        HandMetrics.active = ScaleConsensus.handMetrics(words: data.words)
    }

    /// Rendered body height (unit space) of the glyph this word would resolve
    /// to right now — the layout uses it to even out the line before writing.
    /// Letter-class aware: only x-body letters are measured, so ascenders and
    /// descenders never masquerade as "this word is too big".
    func unitBodyHeight(forWord word: String) -> CGFloat? {
        guard let (g, _) = resolveWordGlyph(word) else { return nil }
        return ScaleConsensus.bodyHeight(word: normalize(word), glyph: g)
            ?? GlyphAlign.bodyHeight(g)
    }

    // MARK: - Profile

    var profile: HandwritingProfile { data.profile ?? HandwritingProfile() }

    func absorbProfile(connectedness: CGFloat?, wordGapUnits: CGFloat?) {
        var p = data.profile ?? HandwritingProfile()
        p.absorb(connectedness: connectedness, wordGapUnits: wordGapUnits)
        data.profile = p
        save()
    }

    func removeGlyph(for ch: Character) {
        data.glyphs[String(ch)] = nil
        OpticalKern.invalidateAll()
        GlyphPDM.shared.invalidateAll()
        invalidateConsensus()
        save()
    }

    func removeWord(_ word: String) {
        data.words[normalize(word)] = nil
        vaeCache.removeValue(forKey: normalize(word))
        invalidateConsensus()
        save()
    }

    /// All saved variants for review in the training UI.
    func variants(forChar ch: Character) -> [PersonalGlyph] {
        data.glyphs[String(ch)] ?? []
    }

    func variants(forWord word: String) -> [PersonalGlyph] {
        data.words[normalize(word)] ?? []
    }

    func removeVariant(forChar ch: Character, at index: Int) {
        let key = String(ch)
        guard var list = data.glyphs[key], list.indices.contains(index) else { return }
        list.remove(at: index)
        data.glyphs[key] = list.isEmpty ? nil : list
        OpticalKern.invalidateAll()
        GlyphPDM.shared.invalidateAll()
        save()
    }

    func removeVariant(forWord word: String, at index: Int) {
        let key = normalize(word)
        guard var list = data.words[key], list.indices.contains(index) else { return }
        list.remove(at: index)
        data.words[key] = list.isEmpty ? nil : list
        invalidateConsensus()
        save()
    }

    /// Renders a stored glyph into view-space ink without StyleRL jitter (for previews).
    func previewInk(for g: PersonalGlyph, in rect: CGRect, padding: CGFloat = 8) -> [InkStroke] {
        let usable = rect.insetBy(dx: padding, dy: padding)
        guard usable.width > 4, usable.height > 4 else { return [] }
        // Fit width and leave room for ascenders (~1.7) + descenders (~0.7).
        let unitH: CGFloat = 2.5
        let scale = min(usable.width / max(0.2, g.width + 0.1),
                        usable.height / unitH)
        let originX = usable.minX + (usable.width - g.width * scale) / 2
        let baselineY = usable.minY + usable.height * (1.75 / unitH)
        let baseWidth = max(1.2, scale * 0.11)

        var out: [InkStroke] = []
        for (i, pts) in g.strokes.enumerated() {
            let mapped = pts.map {
                CGPoint(x: originX + $0.x * scale, y: baselineY - $0.y * scale)
            }
            if mapped.count == 1 {
                out.append(InkStroke(points: mapped, isDot: true,
                                     dotRadius: max(1.2, scale * 0.07)))
            } else {
                var stroke = InkStroke(points: mapped)
                if let ws = g.widths, i < ws.count, ws[i].count == pts.count {
                    stroke.widths = ws[i].map { max(1.0, $0 * scale * 0.7 + baseWidth * 0.4) }
                }
                out.append(stroke)
            }
        }
        return out
    }

    // MARK: - Lookup

    private func pickChar(_ ch: Character) -> PersonalGlyph? {
        let key = String(ch)
        let direct = data.glyphs[key]
        let resolvedKey = direct != nil ? key : ch.lowercased().first.map(String.init)
        let list = direct ?? resolvedKey.flatMap { data.glyphs[$0] }
        guard let list, !list.isEmpty, let rk = resolvedKey else { return nil }
        // PDM: sample a fresh in-distribution shape so repeated letters
        // never look cloned. Falls back to bandit variant picking.
        if list.count >= 2,
           let sampled = GlyphPDM.shared.sample(key: "c:\(rk)", variants: list) {
            return sampled
        }
        let idx = StyleRL.shared.pickVariantIndex(key: "c:\(rk)", glyphs: list, letterCount: 1)
        return list[idx]
    }

    private func pickWord(_ word: String) -> PersonalGlyph? {
        let key = normalize(word)
        guard let list = data.words[key], !list.isEmpty else { return nil }
        let idx = StyleRL.shared.pickVariantIndex(key: "w:\(key)", glyphs: list,
                                                  letterCount: max(1, key.count))
        return list[idx]
    }

    func hasWord(_ word: String) -> Bool { data.words[normalize(word)] != nil }
    func hasChar(_ ch: Character) -> Bool {
        data.glyphs[String(ch)] != nil
            || ch.lowercased().first.map { data.glyphs[String($0)] != nil } == true
    }

    // MARK: - Composition

    private func compose(_ raw: PersonalGlyph,
                         originX: CGFloat, baselineY: CGFloat,
                         size: CGFloat, messiness: CGFloat,
                         source: WordInkSource = .letters) -> (strokes: [InkStroke], advance: CGFloat) {
        let style = StyleRL.shared.active
        let m = messiness * style.messinessScale
        // Sigma-lognormal-style retiming: same geometry, freshly humanized
        // velocity/pause timing on every render.
        let g = SigmaLognormal.retime(raw, variability: 0.45 + m * 0.5)
        // Size stays nearly locked — tiny breathing only. Big size jumps read as bad training.
        let sz = size * (1 + CGFloat.random(in: -0.5...0.5) * 0.02 * m)
        // Horizontal nudge only. Vertical jump per glyph is what made letters look "up/down".
        let wobbleX = CGFloat.random(in: -0.8...0.8) * 0.9 * m
        let baseWidth = max(1.5, size * 0.11)
        var tempoScale = Double(sqrt(max(0.05, sz / max(10, g.refSize ?? 95))))
        tempoScale *= Double(1 + CGFloat.random(in: -1...1) * style.tempoJitter)
        var result: [InkStroke] = []

        func toView(_ u: CGPoint) -> CGPoint {
            let jx = CGFloat.random(in: -0.5...0.5) * size * 0.015 * m
            // Micro ink tremor only — not baseline shifts.
            let jy = CGFloat.random(in: -0.5...0.5) * size * 0.008 * m
            return CGPoint(x: originX + u.x * sz + jx + wobbleX * 0.15,
                           y: baselineY - u.y * sz + jy)
        }
        func viewWidth(_ wn: CGFloat) -> CGFloat {
            max(1.1, (wn * sz * 0.55 + baseWidth * 0.55) * style.pressureGain)
        }

        for (i, pts) in g.strokes.enumerated() {
            let ws = g.widths.flatMap { i < $0.count ? $0[i] : nil }
            let dur = g.durations.flatMap { i < $0.count ? $0[i] : nil }
            let gap = g.gaps.flatMap { i < $0.count ? $0[i] : nil }
            let times = g.pointTimes.flatMap { i < $0.count ? $0[i] : nil }
            var stroke: InkStroke
            if pts.count == 1 {
                stroke = InkStroke(points: [toView(pts[0])],
                                   isDot: true, dotRadius: max(1.4, size * 0.07))
            } else {
                stroke = InkStroke(points: pts.map(toView))
                if let ws, ws.count == pts.count {
                    stroke.widths = ws.map(viewWidth)
                }
                if let dur, dur > 0.02 { stroke.duration = dur * tempoScale }
            }
            if let gap, i > 0 { stroke.pauseBefore = gap * (0.5 + 0.5 * tempoScale) }
            if let times, times.count == pts.count {
                stroke.pointTimes = times.map { $0 * tempoScale }
            }
            if let values = g.forces, i < values.count { stroke.forces = values[i] }
            if let values = g.altitudes, i < values.count { stroke.altitudes = values[i] }
            if let values = g.azimuths, i < values.count { stroke.azimuths = values[i] }
            stroke.source = source
            stroke.confidence = {
                switch source {
                case .exact: return 1
                case .fragments: return 0.82
                case .vae: return 0.66
                case .letters: return 0.52
                }
            }()
            result.append(stroke)
        }

        let spacing = StrokeFont.letterSpacing
            * (1 - 0.55 * min(1, profile.connectedness))
            * style.spacingScale
        return (result, (g.width + spacing) * sz)
    }

    /// Resolve a word: exact → fragment stitch → VAE → nil.
    /// Everything then gets sentence-unity morph so the line shares one hand.
    func inkStrokes(forWord word: String,
                    originX: CGFloat, baselineY: CGFloat,
                    size: CGFloat, messiness: CGFloat) -> (strokes: [InkStroke], advance: CGFloat)? {
        guard let (g, source) = resolveWordGlyph(word) else { return nil }
        return compose(g, originX: originX, baselineY: baselineY, size: size,
                       messiness: messiness, source: source)
    }

    /// A single trained character in the user's hand, or nil.
    func inkStrokes(for ch: Character,
                    originX: CGFloat, baselineY: CGFloat,
                    size: CGFloat, messiness: CGFloat) -> (strokes: [InkStroke], advance: CGFloat)? {
        guard let g = pickChar(ch) else { return nil }
        // LINE TRUST: render the letter at the size it was trained relative to
        // the guide lines — no isolatedGain rescale, no ZoneFit zone stretch.
        // Statistical resizing/stretching distorted trained letterforms.
        let unified = GlyphAlign.reseat(InkUnity.shared.unify(g, source: .letters))
        return compose(unified, originX: originX, baselineY: baselineY, size: size,
                       messiness: messiness, source: .letters)
    }

    func advance(_ ch: Character, size: CGFloat) -> CGFloat? {
        pickChar(ch).map { ($0.width + StrokeFont.letterSpacing) * size }
    }

    func wordAdvance(_ word: String, size: CGFloat) -> CGFloat? {
        resolveWordGlyph(word).map { ($0.glyph.width + StrokeFont.letterSpacing) * size }
    }

    /// How much of this word is covered by real user ink (exact or fragments).
    func inkCoverage(of word: String) -> CGFloat {
        let key = normalize(word)
        if data.words[key] != nil { return 1 }
        return FragmentBank.shared.coverage(of: key)
    }

    var trainedWordList: [String] { Array(data.words.keys) }

    private var vaeCache: [String: (PersonalGlyph, WordInkSource)] = [:]

    private func resolveWordGlyph(_ word: String) -> (glyph: PersonalGlyph, source: WordInkSource)? {
        let key = normalize(word)
        if let cached = vaeCache[key] { return cached }

        var resolved: (PersonalGlyph, WordInkSource)?

        if let g = pickWord(word) {
            resolved = (g, .exact)
        } else if key.count >= 2, key.allSatisfy(\.isLetter),
                  let g = FragmentBank.shared.stitch(key, connectedness: profile.connectedness) {
            resolved = (g, .fragments)
        } else if let g = synthesizeWithVAE(key) {
            resolved = (g, .vae)
        }

        guard let resolved else { return nil }
        var glyph = resolved.0
        let source = resolved.1
        glyph = InkUnity.shared.unify(glyph, source: source)
        // Morph can nudge baseline — reseat so the line stays level.
        // (Shift only. ZoneFit zone-stretching is deliberately gone: locally
        // warping ascenders/descenders skewed the user's letterforms.)
        glyph = GlyphAlign.reseat(glyph)
        if vaeCache.count > 64 { vaeCache.removeAll(keepingCapacity: true) }
        vaeCache[key] = (glyph, source)
        return (glyph, source)
    }

    private func synthesizeWithVAE(_ key: String) -> PersonalGlyph? {
        guard StrokeVAE.shared.isReady,
              key.count >= 2,
              key.allSatisfy(\.isLetter) else { return nil }

        var pairs: [(Character, PersonalGlyph)] = []
        for ch in key {
            guard let g = peekChar(ch) else { return nil }
            pairs.append((ch, g))
        }
        return StrokeVAE.shared.synthesizeWord(key,
                                               letterGlyphs: pairs,
                                               connectedness: profile.connectedness)
    }

    /// Drop cached morphs at the start of a reply.
    func clearVAECache() { vaeCache.removeAll(keepingCapacity: true) }

    /// Variant pick without recording a StyleRL episode arm (for VAE packing).
    private func peekChar(_ ch: Character) -> PersonalGlyph? {
        let key = String(ch)
        let direct = data.glyphs[key]
        let resolvedKey = direct != nil ? key : ch.lowercased().first.map(String.init)
        let list = direct ?? resolvedKey.flatMap { data.glyphs[$0] }
        guard let list, !list.isEmpty else { return nil }
        if list.count >= 2, let rk = resolvedKey,
           let sampled = GlyphPDM.shared.sample(key: "c:\(rk)", variants: list) {
            return sampled
        }
        return list.randomElement()
    }

    // MARK: - Persistence

    private let saver = DebouncedSaver()

    private func save() {
        let snapshot = data
        let url = fileURL
        saver.schedule {
            DebouncedSaver.write(snapshot, to: url, label: "PersonalFontStore")
        }
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL) else {
            return
        }
        if let decoded = try? JSONDecoder().decode(PersonalFontData.self, from: raw) {
            data = decoded
        } else if let v1 = try? JSONDecoder().decode([String: PersonalGlyph].self, from: raw) {
            // Migrate the old single-variant, letters-only format.
            data.glyphs = v1.mapValues { [$0] }
            save()
        }
        var pruned = false
        for key in Array(data.glyphs.keys) {
            if let variants = data.glyphs[key], variants.count > Self.maxVariants {
                data.glyphs[key] = Array(variants.suffix(Self.maxVariants))
                pruned = true
            }
        }
        for key in Array(data.words.keys) {
            guard var variants = data.words[key] else { continue }
            // Purge legacy paragraph-trainer captures — auto-segmentation made
            // them noisy and they degrade synthesis.
            let kept = variants.filter { $0.paragraphCaptureID == nil }
            if kept.count != variants.count {
                variants = kept
                pruned = true
            }
            if variants.count > Self.maxVariants {
                variants = Array(variants.suffix(Self.maxVariants))
                pruned = true
            }
            data.words[key] = variants.isEmpty ? nil : variants
        }
        if pruned {
            rebuildDerivedModels()
            save()
        }
        StrokeVAE.shared.bootstrapIfNeeded(words: data.words)
        FragmentBank.shared.bootstrap(words: data.words)
        LigatureEngine.shared.bootstrap(words: data.words)
        HandMetrics.active = ScaleConsensus.handMetrics(words: data.words)
        realignStoredGlyphsIfNeeded()
        applyScaleConsensusIfNeeded()
    }

    /// One-shot migration: cross-calibrate all existing captures so the same
    /// letter has the same body size everywhere. New captures get calibrated
    /// on the way in (addWord), so this only needs to run once.
    private func applyScaleConsensusIfNeeded() {
        // v2: v1 ran with the whole-word column measure (ascender-heavy words
        // mis-corrected) and without tittle exclusion — re-solve with the
        // letter-aware, dot-blind measurement. Uniform rescales are lossless,
        // so re-running recovers rather than compounds.
        let flag = "penpal.scaleConsensus.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)

        let result = ScaleConsensus.solve(words: data.words, chars: data.glyphs)
        guard result.changed else { return }
        for (key, scales) in result.wordScales {
            guard var list = data.words[key], list.count == scales.count else { continue }
            for i in list.indices where abs(scales[i] - 1) > 0.04 {
                list[i] = GlyphAlign.reseat(ScaleConsensus.apply(scales[i], to: list[i]))
            }
            data.words[key] = list
        }
        for (key, scales) in result.charScales {
            guard var list = data.glyphs[key], list.count == scales.count else { continue }
            for i in list.indices where abs(scales[i] - 1) > 0.04 {
                list[i] = GlyphAlign.reseat(ScaleConsensus.apply(scales[i], to: list[i]))
            }
            data.glyphs[key] = list
        }
        invalidateConsensus()
        // Fragments/VAE/critic/kerning/PDM were built from pre-consensus glyphs.
        rebuildDerivedModels()
        OpticalKern.invalidateAll()
        GlyphPDM.shared.invalidateAll()
        save()
    }

    /// One-shot migration: v1 samples weren't auto-aligned; v2 widened the
    /// word-scale clamp; v3 fixes tall-letter normalization (bowl-scaled
    /// b/d/h/k, caps/digits to cap height instead of being squashed);
    /// v4 re-runs CHARS ONLY with punctuation height classes (?/! were
    /// squashed to x-height) and learned HandMetrics targets; v5 adds the
    /// tittle exclusion (i/j dots inflated height → stems shrunk) and line
    /// trust. Words are deliberately NOT re-run through the quantile fit —
    /// it would re-squash ascender-heavy words; their scale is owned by
    /// ScaleConsensus.
    private func realignStoredGlyphsIfNeeded() {
        let flag = "penpal.glyphsAligned.v6"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let firstRun = !UserDefaults.standard.bool(forKey: "penpal.glyphsAligned.v3")
        for (key, list) in data.glyphs {
            let ch = key.first
            data.glyphs[key] = list.map { GlyphAlign.normalize($0, forChar: ch) }
        }
        if firstRun {
            for (key, list) in data.words {
                data.words[key] = list.map { GlyphAlign.normalize($0, forChar: nil) }
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
        UserDefaults.standard.set(true, forKey: "penpal.glyphsAligned.v3")
        // Fragments/VAE/critic/kerning/PDM were built from the old-scale glyphs.
        rebuildDerivedModels()
        OpticalKern.invalidateAll()
        GlyphPDM.shared.invalidateAll()
        save()
    }
}
