import XCTest
import CoreGraphics
@testable import penpal

@MainActor
final class IllustrationPlotterTests: XCTestCase {

    func testIllustratorOffersQuickBalancedAndDetailedQuality() {
        XCTAssertEqual(
            PenpalControlOptions.illustratorQualities.map(\.tag),
            ["quick", "balanced", "detailed"]
        )
        XCTAssertEqual(
            PenpalControlOptions.illustratorQualities.last?.title,
            "Detailed (slower)"
        )
    }

    func testDrawingFrameUsesFullNoteWidthAndPreservesAspectRatio() {
        let landscape = IllustrationPlotter.drawingFrame(
            origin: CGPoint(x: 60, y: 100),
            maxWidth: 700,
            aspectRatio: 2
        )
        XCTAssertEqual(landscape, CGRect(x: 60, y: 100, width: 700, height: 350))

        let portrait = IllustrationPlotter.drawingFrame(
            origin: .zero,
            maxWidth: 700,
            aspectRatio: 0.5
        )
        XCTAssertEqual(portrait.width, 700)
        XCTAssertEqual(portrait.height, 1_400)
    }

    func testNormalisedPlanMapsIntoPageFrameInOrder() {
        let plan = [
            PenpalAPI.Illustration.Stroke(
                role: "outline",
                points: [[0.1, 0.2], [0.5, 0.1], [0.9, 0.2]]
            ),
            PenpalAPI.Illustration.Stroke(
                role: "detail",
                points: [[0.3, 0.6], [0.5, 0.8], [0.7, 0.6]]
            ),
        ]
        let frame = CGRect(x: 60, y: 100, width: 400, height: 400)

        let strokes = IllustrationPlotter.strokes(from: plan, in: frame)

        XCTAssertEqual(strokes.count, 2)
        XCTAssertEqual(strokes[0].points.first, CGPoint(x: 100, y: 180))
        XCTAssertEqual(strokes[0].points.last, CGPoint(x: 420, y: 180))
        XCTAssertGreaterThan(strokes[0].points.count, plan[0].points.count)
        XCTAssertGreaterThan(strokes[0].confidence, strokes[1].confidence)
    }

    func testInvalidCoordinatesAndShortStrokesAreDropped() {
        let plan = [
            PenpalAPI.Illustration.Stroke(
                role: "outline",
                points: [[-0.2, 0.5], [1.2, 0.5]]
            ),
            PenpalAPI.Illustration.Stroke(
                role: "detail",
                points: [[0.5, 0.5]]
            ),
        ]

        XCTAssertTrue(
            IllustrationPlotter.strokes(
                from: plan,
                in: CGRect(x: 0, y: 0, width: 300, height: 300)
            ).isEmpty
        )
    }

    func testDetailedPlansUseTimeLapsedDurations() {
        let points = (0...100).map { index in
            [Double(index) / 100, 0.5]
        }
        let plan = [PenpalAPI.Illustration.Stroke(role: "detail", points: points)]

        let stroke = IllustrationPlotter.strokes(
            from: plan,
            in: CGRect(x: 0, y: 0, width: 600, height: 600)
        )[0]

        XCTAssertLessThanOrEqual(stroke.duration ?? 10, 0.95)
        XCTAssertGreaterThanOrEqual(stroke.duration ?? 0, 0.11)
    }

    func testPathsFollowNearestEndpointAndReverseWhenUseful() {
        let plan = [
            PenpalAPI.Illustration.Stroke(
                role: "outline",
                points: [[0.10, 0.10], [0.20, 0.10]]
            ),
            PenpalAPI.Illustration.Stroke(
                role: "outline",
                points: [[0.80, 0.80], [0.90, 0.80]]
            ),
            PenpalAPI.Illustration.Stroke(
                role: "outline",
                points: [[0.50, 0.10], [0.21, 0.10]]
            ),
        ]

        let strokes = IllustrationPlotter.strokes(
            from: plan,
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )

        XCTAssertEqual(strokes.count, 3)
        XCTAssertEqual(strokes[1].points.first?.x ?? 0, 84, accuracy: 0.01)
        XCTAssertEqual(strokes[1].points.last?.x ?? 0, 200, accuracy: 0.01)
        XCTAssertLessThan(strokes[1].pauseBefore ?? 1, strokes[2].pauseBefore ?? 0)
    }

    func testPressureTapersAndDetailsDrawMoreCarefully() {
        let shared = [[0.1, 0.5], [0.5, 0.2], [0.9, 0.5]]
        let plan = [
            PenpalAPI.Illustration.Stroke(role: "outline", points: shared),
            PenpalAPI.Illustration.Stroke(role: "detail", points: shared),
        ]

        let strokes = IllustrationPlotter.strokes(
            from: plan,
            in: CGRect(x: 0, y: 0, width: 400, height: 400),
            baseWidth: 1.5
        )

        let outlineWidths = try! XCTUnwrap(strokes[0].widths)
        XCTAssertEqual(outlineWidths.count, strokes[0].points.count)
        XCTAssertLessThan(outlineWidths[0], outlineWidths[outlineWidths.count / 2])
        XCTAssertGreaterThan(strokes[1].duration ?? 0, strokes[0].duration ?? 1)
        XCTAssertGreaterThanOrEqual(strokes[1].pauseBefore ?? 0, 0.12)
    }
}
