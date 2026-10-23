import XCTest
@testable import penpal

/// PEN-40 — the arranger's layout solver.
///
/// These lock the four behaviours that decide whether a generated page reads
/// as a note or as a stack of widgets: caption gravity, overflow promotion,
/// grid snapping, and honest degradation on a narrow page.
final class PageComposerTests: XCTestCase {

    // MARK: Fixtures

    /// A realistic iPad page: 740pt of writable width on 26pt ruled lines.
    private func page(width: CGFloat = 740,
                      columns: Int = 2,
                      lineGap: CGFloat = 26) -> PageMetrics {
        PageMetrics(originX: 48,
                    contentWidth: width,
                    topY: 100,
                    lineGap: lineGap,
                    gutter: 20,
                    maxColumns: columns)
    }

    /// Deterministic stand-in for the handwriting engine: ~7.3pt per
    /// character, wrapped to the column, one ruled line per wrapped line.
    private var metrics: SectionMetrics {
        SectionMetrics(
            inkHeight: { text, width in
                guard !text.isEmpty else { return 0 }
                let perLine = max(8, width / 7.3)
                return (CGFloat(text.count) / perLine).rounded(.up) * 26
            },
            blockHeight: { preferred, _ in min(max(preferred, 140), 520) },
            diagramHeight: { aspect, width in width / aspect }
        )
    }

    private func section(_ id: String,
                         _ role: SectionRole,
                         _ block: SectionBlock,
                         _ span: SectionSpan,
                         _ priority: Int,
                         anchor: String? = nil,
                         adjacency: SectionAdjacency? = nil,
                         text: String = "",
                         preferredHeight: CGFloat = 0,
                         aspectRatio: CGFloat = 1) -> ArrangedSection {
        ArrangedSection(id: id, role: role, block: block, span: span,
                        priority: priority, anchor: anchor, adjacency: adjacency,
                        text: text, html: "",
                        preferredHeight: preferredHeight, aspectRatio: aspectRatio)
    }

    private let shortText = String(repeating: "The armature spins. ", count: 3)
    private let longText = String(
        repeating: "The armature rotates within the magnetic field and the "
                 + "commutator reverses the connection each half turn. ",
        count: 9)

    // MARK: The worked example

    /// The canonical request: draw a DC generator, explain it, work an
    /// example, then animate it. The explanation must sit UNDER its diagram
    /// (not beside it, not three bands away), the example takes the facing
    /// column, and the animation gets the full measure below both.
    func testDiagramExplanationExampleAnimationFormsANote() throws {
        let composition = PageComposer.compose(
            sections: [
                section("diagram", .diagram, .diagram, .half, 1, aspectRatio: 1.3),
                section("explain", .explanation, .ink, .half, 2,
                        anchor: "diagram", adjacency: .below, text: shortText),
                section("example", .example, .ink, .half, 3, text: shortText),
                section("animate", .animation, .interactive, .full, 4,
                        preferredHeight: 380),
            ],
            template: .modularGrid,
            page: page(),
            metrics: metrics)

        let diagram = try XCTUnwrap(composition.placements.first { $0.id == "diagram" })
        let explain = try XCTUnwrap(composition.placements.first { $0.id == "explain" })
        let example = try XCTUnwrap(composition.placements.first { $0.id == "example" })
        let animate = try XCTUnwrap(composition.placements.first { $0.id == "animate" })

        // Caption gravity: same column, explanation directly beneath.
        XCTAssertEqual(explain.column, diagram.column)
        XCTAssertEqual(explain.band, diagram.band)
        XCTAssertGreaterThan(explain.frame.minY, diagram.frame.minY)
        XCTAssertEqual(explain.frame.minX, diagram.frame.minX)

        // The example takes the facing column of the same band, top-aligned.
        XCTAssertEqual(example.band, diagram.band)
        XCTAssertEqual(example.column, 1)
        XCTAssertEqual(example.frame.minY, diagram.frame.minY)
        XCTAssertGreaterThan(example.frame.minX, diagram.frame.maxX - 1)

        // The animation gets its own full-width band underneath everything.
        XCTAssertEqual(animate.column, 0)
        XCTAssertGreaterThan(animate.band, diagram.band)
        XCTAssertEqual(animate.frame.width, 740, accuracy: 0.5)
        XCTAssertGreaterThan(animate.frame.minY, explain.frame.maxY)
        XCTAssertGreaterThan(animate.frame.minY, example.frame.maxY)
    }

    /// The rule the request called out by name: when the explanation outgrows
    /// its column, a person stops squeezing it and starts a new line across
    /// the whole page. It must not spill into the neighbouring column, and it
    /// must not reorder itself past the animation that follows it.
    func testOversizedSectionIsPromotedToItsOwnFullWidthBand() throws {
        let composition = PageComposer.compose(
            sections: [
                section("diagram", .diagram, .diagram, .half, 1, aspectRatio: 1.3),
                section("explain", .explanation, .ink, .half, 2,
                        anchor: "diagram", adjacency: .below, text: longText),
                section("example", .example, .ink, .half, 3, text: shortText),
                section("animate", .animation, .interactive, .full, 4,
                        preferredHeight: 380),
            ],
            template: .modularGrid,
            page: page(),
            metrics: metrics)

        let diagram = try XCTUnwrap(composition.placements.first { $0.id == "diagram" })
        let explain = try XCTUnwrap(composition.placements.first { $0.id == "explain" })
        let example = try XCTUnwrap(composition.placements.first { $0.id == "example" })
        let animate = try XCTUnwrap(composition.placements.first { $0.id == "animate" })

        XCTAssertTrue(explain.wasPromoted)
        XCTAssertEqual(explain.frame.width, 740, accuracy: 0.5)
        XCTAssertEqual(explain.frame.minX, 48, accuracy: 0.5)
        // Below the band it came from, above what follows: reading order held.
        XCTAssertGreaterThan(explain.frame.minY, diagram.frame.maxY)
        XCTAssertGreaterThan(explain.frame.minY, example.frame.maxY)
        XCTAssertGreaterThan(animate.frame.minY, explain.frame.maxY)
        // Nothing else was disturbed by the promotion.
        XCTAssertFalse(diagram.wasPromoted)
        XCTAssertEqual(diagram.band, example.band)
    }

    // MARK: Grid

    /// Every band lands on a ruled line. This is the single detail that makes
    /// the result read as written on the paper rather than pasted onto it.
    func testEveryPlacementLandsOnARuledLine() throws {
        let sheet = self.page()
        let composition = PageComposer.compose(
            sections: [
                section("a", .diagram, .diagram, .half, 1, aspectRatio: 1.37),
                section("b", .explanation, .ink, .half, 2, text: shortText),
                section("c", .example, .ink, .full, 3, text: longText),
                section("d", .animation, .interactive, .full, 4, preferredHeight: 337),
            ],
            template: .modularGrid,
            page: sheet,
            metrics: self.metrics)

        XCTAssertFalse(composition.placements.isEmpty)
        for placed in composition.placements {
            let offset = (placed.frame.minY - sheet.topY)
                .truncatingRemainder(dividingBy: sheet.lineGap)
            XCTAssertEqual(offset, 0, accuracy: 0.001,
                           "\(placed.id) sits between two ruled lines")
            let height = placed.frame.height
                .truncatingRemainder(dividingBy: sheet.lineGap)
            XCTAssertEqual(height, 0, accuracy: 0.001,
                           "\(placed.id) is not a whole number of lines tall")
        }
    }

    // MARK: Role habits

    /// A title opens the page full width whatever the planner asked for, and
    /// a summary sinks to the foot even when planned in the middle — the
    /// Cornell habit of synthesis sitting under what it synthesises.
    func testTitleLeadsAndSummarySinks() throws {
        let composition = PageComposer.compose(
            sections: [
                section("title", .title, .ink, .half, 1, text: "Cardiovascular system"),
                section("recap", .summary, .ink, .half, 2, text: shortText),
                section("a", .explanation, .ink, .half, 3, text: shortText),
                section("b", .example, .ink, .half, 4, text: shortText),
            ],
            template: .modularGrid,
            page: page(),
            metrics: metrics)

        let title = try XCTUnwrap(composition.placements.first { $0.id == "title" })
        let recap = try XCTUnwrap(composition.placements.first { $0.id == "recap" })
        let bodyA = try XCTUnwrap(composition.placements.first { $0.id == "a" })
        let bodyB = try XCTUnwrap(composition.placements.first { $0.id == "b" })

        XCTAssertEqual(title.frame.width, 740, accuracy: 0.5)
        XCTAssertEqual(title.band, 0)
        XCTAssertLessThan(title.frame.minY, bodyA.frame.minY)
        // Planned second, laid out last.
        XCTAssertGreaterThan(recap.frame.minY, bodyA.frame.maxY)
        XCTAssertGreaterThan(recap.frame.minY, bodyB.frame.maxY)
    }

    // MARK: Degradation

    /// A phone-width page cannot carry two readable columns of handwriting.
    /// Honouring the plan there would ship 140pt columns; collapsing to one
    /// column is the honest answer.
    func testNarrowPageCollapsesToASingleColumn() throws {
        let narrow = PageMetrics(originX: 24, contentWidth: 330, topY: 60,
                                 lineGap: 24, gutter: 16, maxColumns: 2)
        let composition = PageComposer.compose(
            sections: [
                section("d", .diagram, .diagram, .half, 1, aspectRatio: 1.4),
                section("e", .explanation, .ink, .half, 2,
                        anchor: "d", adjacency: .beside, text: shortText),
            ],
            template: .modularGrid,
            page: narrow,
            metrics: metrics)

        for placed in composition.placements {
            XCTAssertEqual(placed.column, 0)
            XCTAssertEqual(placed.frame.width, 330, accuracy: 0.5)
        }
        let diagram = try XCTUnwrap(composition.placements.first { $0.id == "d" })
        let explain = try XCTUnwrap(composition.placements.first { $0.id == "e" })
        // "beside" degrades to "below" rather than being dropped.
        XCTAssertGreaterThan(explain.frame.minY, diagram.frame.minY)
    }

    /// `path` is a sequence, so it never packs two steps into one band even
    /// when they would fit — order beats density for a process.
    func testPathTemplateWalksOneStepPerBand() throws {
        let composition = PageComposer.compose(
            sections: [
                section("s1", .explanation, .ink, .half, 1, text: shortText),
                section("s2", .explanation, .ink, .half, 2, text: shortText),
                section("s3", .explanation, .ink, .half, 3, text: shortText),
            ],
            template: .path,
            page: page(),
            metrics: metrics)

        XCTAssertEqual(composition.placements.count, 3)
        XCTAssertEqual(Set(composition.placements.map(\.band)).count, 3)
        for placed in composition.placements {
            XCTAssertEqual(placed.frame.width, 740, accuracy: 0.5)
        }
    }

    /// Columns divide the leftover width in proportion to their spans, so a
    /// half beside a third reads 60/40 rather than being forced to equal.
    func testColumnWidthsFollowTheirSpans() throws {
        let wide = PageMetrics(originX: 48, contentWidth: 1100, topY: 100,
                               lineGap: 26, gutter: 24, maxColumns: 3)
        let composition = PageComposer.compose(
            sections: [
                section("m", .diagram, .diagram, .half, 1, aspectRatio: 1.5),
                section("n", .reference, .table, .third, 2,
                        anchor: "m", adjacency: .beside, preferredHeight: 200),
            ],
            template: .skyscraper,
            page: wide,
            metrics: metrics)

        let m = try XCTUnwrap(composition.placements.first { $0.id == "m" })
        let n = try XCTUnwrap(composition.placements.first { $0.id == "n" })
        XCTAssertEqual(m.band, n.band)
        XCTAssertEqual(m.frame.width / n.frame.width, 1.5, accuracy: 0.01)
        // The band fills the page exactly: no drift, no overflow.
        XCTAssertEqual(n.frame.maxX, wide.originX + wide.contentWidth, accuracy: 0.5)
    }

    /// One idea stays one section. Splitting it into a grid to look clever
    /// is exactly the failure mode the arranger exists to avoid.
    func testSingleSectionStaysASinglePlainBand() throws {
        let composition = PageComposer.compose(
            sections: [section("only", .explanation, .ink, .full, 1, text: shortText)],
            template: .modularGrid,
            page: page(),
            metrics: metrics)

        XCTAssertEqual(composition.placements.count, 1)
        XCTAssertEqual(composition.bandCount, 1)
        XCTAssertEqual(composition.placements[0].frame.minY, 100, accuracy: 0.5)
    }

    func testEmptyPlanProducesAnEmptyComposition() throws {
        let composition = PageComposer.compose(
            sections: [], template: .modularGrid,
            page: page(), metrics: metrics)
        XCTAssertTrue(composition.placements.isEmpty)
        XCTAssertEqual(composition.contentBottom, 100)
        XCTAssertEqual(composition.bandCount, 0)
    }
}
