import XCTest
import PencilKit
@testable import penpal

@MainActor
final class TrainedHandwritingTests: XCTestCase {
    private func letter(_ offset: CGFloat = 0) -> PersonalGlyph {
        PersonalGlyph(width: 0.8, strokes: [[
            CGPoint(x: 0, y: 0), CGPoint(x: 0.2, y: 0.8 + offset),
            CGPoint(x: 0.5, y: 1), CGPoint(x: 0.8, y: 0)
        ]])
    }

    private func withBank(_ body: (PersonalFontStore) throws -> Void) throws {
        let profiles = HandProfiles.shared
        let original = try XCTUnwrap(profiles.activeID)
        let fixture = profiles.addProfile(named: "Handwriting regression fixture")
        profiles.activate(fixture.id)
        defer { profiles.activate(original); profiles.delete(fixture.id) }
        let a = letter(), b = letter(-0.3)
        let word = PersonalGlyph(width: 2, strokes: a.strokes + b.strokes.map {
            $0.map { CGPoint(x: $0.x + 1.2, y: $0.y) }
        })
        struct Bank: Encodable {
            let schemaVersion = 4
            let glyphs: [String: [PersonalGlyph]]
            let words: [String: [PersonalGlyph]]
            let profile = HandwritingProfile(connectedness: 1, wordGapUnits: 0.9, samples: 1)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(Bank(glyphs: ["a": [a], "b": [b]], words: ["ab": [word]])).write(to: url)
        let store = PersonalFontStore.shared
        try store.installGlyphBank(from: url)
        StyleRL.shared.beginEpisode(explore: false)
        try body(store)
    }

    func testPrintIsNotClassifiedAsFullyCursive() {
        let strokes = (0..<5).map { index in
            letter().strokes[0].map { CGPoint(x: $0.x + CGFloat(index), y: $0.y) }
        }
        let printed = PersonalGlyph(width: 5, strokes: strokes)
        XCTAssertEqual(PersonalFontStore.estimatedConnectedness(of: printed, letterCount: 5), 0)
        let joined = PersonalGlyph(width: 5, strokes: [strokes.flatMap { $0 }, [CGPoint(x: 2, y: 1.5)]])
        XCTAssertEqual(PersonalFontStore.estimatedConnectedness(of: joined, letterCount: 5), 1)
    }

    func testExistingProfileIsRepairedWithoutReplacingSamples() throws {
        try withBank { store in
            XCTAssertEqual(store.profile.connectedness, 0)
            XCTAssertEqual(store.profile.wordGapUnits, 0.9)
            XCTAssertEqual(store.variants(forChar: "a").count, 1)
            XCTAssertEqual(store.variants(forWord: "ab").count, 1)
            let before = store.variants(forWord: "ab")[0].strokes
            store.reloadForActiveHand()
            XCTAssertEqual(store.profile.connectedness, 0)
            XCTAssertEqual(store.profile.wordGapUnits, 0.9)
            XCTAssertEqual(store.variants(forWord: "ab")[0].strokes, before)
            XCTAssertEqual(store.missingLowercaseLetters, "cdefghijklmnopqrstuvwxyz")
        }
    }

    func testUnseenWordUsesCapturedLettersWithoutInventedStrokes() throws {
        try withBank { store in
            // Prime the experimental cache: normal layout must never reuse it.
            _ = store.wordAdvance("ba", size: 20, allowSynthesis: true)
            XCTAssertNil(store.wordAdvance("ba", size: 20))
            XCTAssertEqual(store.inkCoverage(of: "ba"), 1)
            XCTAssertEqual(store.inkCoverage(of: "cat"), 1.0 / 3.0, accuracy: 0.0001)
            let sequence = StrokeFont.layoutSequence(
                text: "ba", origin: CGPoint(x: 20, y: 60), xHeight: 20,
                maxX: 400, lineGap: 44, maxY: 300, messiness: 0,
                useUserHand: true, settings: .shared)
            XCTAssertEqual(sequence.strokes.count, 2, "No cropped fragments or invented connecting strokes")
            for (index, ch) in Array("ba").enumerated() {
                let expected = try XCTUnwrap(store.inkStrokes(for: ch, originX: 0,
                    baselineY: 60, size: 20, messiness: 0)?.strokes.first)
                let actual = sequence.strokes[index]
                XCTAssertEqual(actual.source, .letters)
                XCTAssertEqual(actual.confidence, 1)
                XCTAssertEqual(actual.points.count, expected.points.count)
                let dx = actual.points[0].x - expected.points[0].x
                for (p, q) in zip(actual.points, expected.points) {
                    XCTAssertEqual(p.x - dx, q.x, accuracy: 0.0001)
                    XCTAssertEqual(p.y, q.y, accuracy: 0.0001)
                }
            }
            XCTAssertGreaterThan(sequence.strokes[1].points.map(\.x).min()!,
                                 sequence.strokes[0].points.map(\.x).max()!)
        }
    }

    func testExactWordKeepsCapturedStrokeGeometry() throws {
        try withBank { store in
            let saved = try XCTUnwrap(store.variants(forWord: "ab").first)
            let result = try XCTUnwrap(store.inkStrokes(forWord: "ab", originX: 20,
                                                       baselineY: 60, size: 20, messiness: 0))
            XCTAssertEqual(result.strokes.count, saved.strokes.count)
            for (actual, captured) in zip(result.strokes, saved.strokes) {
                XCTAssertEqual(actual.source, .exact)
                XCTAssertEqual(actual.points.count, captured.count)
                for (p, q) in zip(actual.points, captured) {
                    XCTAssertEqual(p.x, 20 + q.x * 20, accuracy: 0.0001)
                    XCTAssertEqual(p.y, 60 - q.y * 20, accuracy: 0.0001)
                }
            }
        }
    }
}
