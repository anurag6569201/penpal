import XCTest
import CoreGraphics
@testable import penpal

@MainActor
final class IllustrationPlotterTests: XCTestCase {

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

        XCTAssertLessThanOrEqual(stroke.duration ?? 10, 0.55)
        XCTAssertGreaterThanOrEqual(stroke.duration ?? 0, 0.10)
    }
}
