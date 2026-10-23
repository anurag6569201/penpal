//
//  PageComposer.swift
//  penpal
//
//  PEN-40 — the arranger's layout brain.
//
//  The server plans WHAT a page contains; this decides WHERE it goes. It has
//  to, because only the device knows the page width, the user's handwriting
//  size, and how tall a paragraph will actually be once it is drawn in their
//  hand. A server guessing at geometry produces collisions; measuring here
//  produces a page.
//
//  The model is the one people actually use on paper — not a flow of boxes,
//  but a stack of BANDS, each split into COLUMNS:
//
//      ┌──────────────────────────────────────┐
//      │  title                        (band) │   full
//      ├──────────────────┬───────────────────┤
//      │  diagram         │  worked example   │   two columns
//      │  explanation     │                   │   (explanation is anchored
//      ├──────────────────┴───────────────────┤    below the diagram, so it
//      │  animation                           │    shares its column stack)
//      └──────────────────────────────────────┘
//
//  Three rules do most of the work, and all three are stolen from how people
//  lay out notes by hand:
//
//  1. CAPTION GRAVITY — a section anchored to another stays touching it.
//     An explanation that drifts away from its figure stops being a caption.
//  2. OVERFLOW PROMOTION — when a column's content outgrows its share of the
//     band, it does not spill into a neighbour or run off the page: it is
//     lifted out and given a fresh full-width band underneath. This is the
//     paper habit of "this is getting long, start a new line and use the
//     whole width".
//  3. GRID SNAPPING — every band lands on a ruled line. Handwriting that
//     ignores the rules reads as pasted-on; ink that sits on them reads as
//     written. This single detail is most of the difference between "a note"
//     and "some blocks".
//
//  The type is deliberately free of UIKit and of any measurement of its own:
//  heights arrive through `SectionMetrics`, so the whole solver is a pure
//  function and can be tested without a canvas, a font, or a screen.
//

#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// MARK: - Plan vocabulary

/// What a section is FOR. Role drives placement habits that span has no way
/// to express — a summary belongs at the foot of a page whatever width it is.
enum SectionRole: String, Codable, Hashable {
    case title, diagram, explanation, example, animation
    case summary, reference, checklist, callout

    /// Roles that open a page. A title that lands in column two is not a title.
    var isMasthead: Bool { self == .title }

    /// Roles that close a page. Cornell's summary band is the canonical case:
    /// the synthesis sits under everything it synthesises.
    var isFooter: Bool { self == .summary || self == .checklist }
}

/// Which renderer draws the section.
enum SectionBlock: String, Codable, Hashable {
    case ink            // handwriting drawn straight onto the paper
    case diagram        // illustrator pen strokes
    case interactive    // a live browser block
    case table
    case checklist

    /// Ink is drawn by the handwriting engine; everything else is a PageBlock
    /// subview that needs a frame reserved for it.
    var isEmbeddedBlock: Bool { self != .ink }
}

enum SectionSpan: String, Codable, Hashable {
    case full, half, third

    var fraction: CGFloat {
        switch self {
        case .full:  return 1
        case .half:  return 1.0 / 2.0
        case .third: return 1.0 / 3.0
        }
    }
}

enum SectionAdjacency: String, Codable, Hashable {
    /// Directly underneath the anchor, in the anchor's own column.
    case below
    /// In the next column of the anchor's band.
    case beside
}

/// A layout family. The template does not micro-manage placement; it sets how
/// many columns the page wants and how eagerly sections share a band. Named
/// after the note layouts people actually use.
enum PageTemplate: String, Codable, Hashable {
    case modularGrid = "modular-grid"
    case cornell
    case twoColumn = "two-column"
    case path
    case radial
    case skyscraper

    /// Column count this template reads best at, clamped by the page later.
    var preferredColumns: Int {
        switch self {
        case .modularGrid: return 2
        case .cornell:     return 2
        case .twoColumn:   return 2
        case .path:        return 1
        case .radial:      return 3
        case .skyscraper:  return 3
        }
    }

    /// `path` walks the reader down one step at a time, so its sections never
    /// share a band even when they would fit. Sequence beats density there.
    var packsSectionsSideBySide: Bool { self != .path }
}

/// One planned, already-generated section awaiting a home on the page.
struct ArrangedSection: Identifiable, Hashable {
    var id: String
    var role: SectionRole
    var block: SectionBlock
    var span: SectionSpan
    var priority: Int
    var anchor: String?
    var adjacency: SectionAdjacency?

    /// Content, one of which is populated depending on `block`.
    var text: String = ""
    var html: String = ""

    /// Intrinsic size hints from the generator.
    var preferredHeight: CGFloat = 0
    /// width ÷ height of a drawing, so a figure keeps its proportions when the
    /// column is narrower than the illustrator imagined.
    var aspectRatio: CGFloat = 1
}

// MARK: - Measurement

/// How to turn content into a height at a given width.
///
/// Injected rather than computed here so the solver stays pure: production
/// passes the real handwriting engine, tests pass arithmetic.
struct SectionMetrics {
    /// Height of `text` drawn as handwriting wrapped to `width`.
    var inkHeight: (_ text: String, _ width: CGFloat) -> CGFloat
    /// Height of an embedded block that asked for `preferred` at `width`.
    var blockHeight: (_ preferred: CGFloat, _ width: CGFloat) -> CGFloat
    /// Height of a drawing with `aspectRatio` rendered at `width`.
    var diagramHeight: (_ aspectRatio: CGFloat, _ width: CGFloat) -> CGFloat

    func height(for section: ArrangedSection, width: CGFloat) -> CGFloat {
        switch section.block {
        case .ink:
            return inkHeight(section.text, width)
        case .diagram:
            return diagramHeight(max(0.2, section.aspectRatio), width)
        case .interactive, .table, .checklist:
            return blockHeight(section.preferredHeight, width)
        }
    }
}

// MARK: - Page

/// Everything the solver needs to know about the paper it is composing onto.
struct PageMetrics {
    /// Left edge of the writable area, in canvas content coordinates.
    var originX: CGFloat
    /// Width of the writable area.
    var contentWidth: CGFloat
    /// First baseline the composition may use.
    var topY: CGFloat
    /// Ruled-line pitch. This is the grid unit: every band lands on a multiple.
    var lineGap: CGFloat
    /// Horizontal space between columns.
    var gutter: CGFloat
    /// Vertical space between bands, before snapping.
    var bandSpacing: CGFloat
    /// Hard ceiling on columns, whatever the template wants. A phone-width
    /// page cannot carry three readable columns of handwriting.
    var maxColumns: Int
    /// A column taller than this has outgrown its share of the band and is
    /// promoted to full width. Expressed in points.
    var promotionHeight: CGFloat
    /// Narrowest column that can still hold readable handwriting. Below this
    /// a multi-column band is collapsed rather than shipped unreadable.
    var minimumColumnWidth: CGFloat

    init(originX: CGFloat,
         contentWidth: CGFloat,
         topY: CGFloat,
         lineGap: CGFloat,
         gutter: CGFloat = 20,
         bandSpacing: CGFloat = 0,
         maxColumns: Int = 2,
         promotionHeight: CGFloat = 0,
         minimumColumnWidth: CGFloat = 190) {
        self.originX = originX
        self.contentWidth = max(1, contentWidth)
        self.topY = topY
        self.lineGap = max(1, lineGap)
        self.gutter = max(0, gutter)
        // Default the band gap to a blank ruled line: the same breathing space
        // a person leaves between sections.
        self.bandSpacing = bandSpacing > 0 ? bandSpacing : self.lineGap
        self.maxColumns = max(1, maxColumns)
        // Default promotion at ~18 written lines. Past that a column of
        // handwriting is a wall, and the eye wants the full measure back.
        self.promotionHeight = promotionHeight > 0
            ? promotionHeight
            : self.lineGap * 18
        self.minimumColumnWidth = max(80, minimumColumnWidth)
    }
}

// MARK: - Result

/// Where one section ended up.
struct PlacedSection: Identifiable, Hashable {
    var id: String
    var frame: CGRect
    var block: SectionBlock
    var role: SectionRole
    /// Column index within its band, left to right.
    var column: Int
    var band: Int
    /// True when the section outgrew its column and was given its own band.
    var wasPromoted: Bool
}

/// A solved page.
struct Composition: Hashable {
    var placements: [PlacedSection]
    /// Lowest point any section reaches — what the canvas must grow to.
    var contentBottom: CGFloat
    var bandCount: Int

    func frame(for id: String) -> CGRect? {
        placements.first { $0.id == id }?.frame
    }
}

// MARK: - Solver

enum PageComposer {

    /// Solve a page.
    ///
    /// Sections are consumed in `priority` order — the planner's reading
    /// order — and never reordered, because a note that reads out of sequence
    /// is worse than one that packs imperfectly. The only movement permitted
    /// is *demotion*: a section too big for its column drops to a full-width
    /// band below, which preserves reading order by construction.
    static func compose(sections: [ArrangedSection],
                        template: PageTemplate,
                        page: PageMetrics,
                        metrics: SectionMetrics) -> Composition {
        let ordered = normalise(sections, template: template, page: page)
        guard !ordered.isEmpty else {
            return Composition(placements: [], contentBottom: page.topY, bandCount: 0)
        }

        var placements: [PlacedSection] = []
        var bandIndex = 0
        var cursorY = snapUp(page.topY, page: page)

        for band in assembleBands(ordered, template: template, page: page) {
            let solved = layout(band: band,
                                at: cursorY,
                                bandIndex: bandIndex,
                                page: page,
                                metrics: metrics)
            placements.append(contentsOf: solved.placements)
            // Overflowing stacks are not squeezed: each becomes its own
            // full-width band directly below, keeping reading order intact.
            var nextY = solved.bottom
            for promoted in solved.promoted {
                bandIndex += 1
                nextY = snapUp(nextY + page.bandSpacing, page: page)
                let stack = layout(band: Band(stacks: [ColumnStack(sections: [promoted],
                                                                  fraction: 1)]),
                                   at: nextY,
                                   bandIndex: bandIndex,
                                   page: page,
                                   metrics: metrics,
                                   allowPromotion: false,
                                   markPromoted: true)
                placements.append(contentsOf: stack.placements)
                nextY = stack.bottom
            }
            cursorY = snapUp(nextY + page.bandSpacing, page: page)
            bandIndex += 1
        }

        let bottom = placements.map(\.frame.maxY).max() ?? page.topY
        return Composition(placements: placements,
                           contentBottom: bottom,
                           bandCount: bandIndex)
    }

    // MARK: Normalisation

    /// Apply the habits that are about ROLE and PAGE rather than content:
    /// a title opens full width, a summary sinks to the foot, and spans are
    /// widened when the page is too narrow to split.
    private static func normalise(_ sections: [ArrangedSection],
                                  template: PageTemplate,
                                  page: PageMetrics) -> [ArrangedSection] {
        var ordered = sections.sorted { $0.priority < $1.priority }

        // A page too narrow for two readable columns is a one-column page.
        // Shipping 120pt columns of handwriting to honour a plan is worse
        // than ignoring the plan.
        let columnsFit = Int(
            (page.contentWidth + page.gutter)
            / (page.minimumColumnWidth + page.gutter)
        )
        let allowedColumns = max(1, min(min(page.maxColumns, columnsFit),
                                        template.preferredColumns))

        for index in ordered.indices {
            if ordered[index].role.isMasthead {
                ordered[index].span = .full
                ordered[index].anchor = nil
                ordered[index].adjacency = nil
            }
            if allowedColumns == 1 {
                ordered[index].span = .full
                // `beside` is meaningless in one column; `below` still holds.
                if ordered[index].adjacency == .beside {
                    ordered[index].adjacency = .below
                }
            } else if allowedColumns == 2, ordered[index].span == .third {
                ordered[index].span = .half
            }
        }

        // Cornell and its relatives put synthesis last. Anything the planner
        // marked as a summary or checklist sinks below the body it summarises,
        // keeping its relative order with other footers.
        let body = ordered.filter { !$0.role.isFooter }
        let feet = ordered.filter { $0.role.isFooter }
        ordered = body + feet
        for index in ordered.indices { ordered[index].priority = index + 1 }
        return ordered
    }

    // MARK: Band assembly

    /// A vertical run of sections sharing one column slot.
    fileprivate struct ColumnStack {
        var sections: [ArrangedSection]
        var fraction: CGFloat
    }

    fileprivate struct Band {
        var stacks: [ColumnStack]
        var totalFraction: CGFloat { stacks.reduce(0) { $0 + $1.fraction } }
    }

    /// Group sections into bands, honouring anchors.
    ///
    /// Greedy and single-pass on purpose. Optimal packing would reorder
    /// sections, and reading order is worth more than a tight fit.
    private static func assembleBands(_ sections: [ArrangedSection],
                                      template: PageTemplate,
                                      page: PageMetrics) -> [Band] {
        var bands: [Band] = []
        var current = Band(stacks: [])
        /// Which band and stack each already-placed section landed in, so an
        /// anchored follower can find its target.
        var location: [String: (band: Int, stack: Int)] = [:]

        func closeBand() {
            if !current.stacks.isEmpty {
                bands.append(current)
                current = Band(stacks: [])
            }
        }

        for section in sections {
            // CAPTION GRAVITY. An anchored section is placed relative to its
            // target before any packing rule gets a say.
            if let anchor = section.anchor,
               let adjacency = section.adjacency,
               let target = location[anchor] {
                if target.band == bands.count {
                    // The anchor is in the band still being built.
                    if adjacency == .below {
                        current.stacks[target.stack].sections.append(section)
                        location[section.id] = (bands.count, target.stack)
                        continue
                    }
                    if current.totalFraction + section.span.fraction <= 1.0001 {
                        current.stacks.append(ColumnStack(sections: [section],
                                                          fraction: section.span.fraction))
                        location[section.id] = (bands.count, current.stacks.count - 1)
                        continue
                    }
                } else if adjacency == .below,
                          target.band < bands.count,
                          target.band == bands.count - 1 {
                    // The anchor closed the previous band; rejoin its column
                    // rather than starting a fresh one away from it.
                    bands[target.band].stacks[target.stack].sections.append(section)
                    location[section.id] = (target.band, target.stack)
                    continue
                }
            }

            let wantsOwnBand = section.span == .full
                || !template.packsSectionsSideBySide
                || section.role.isMasthead

            if wantsOwnBand {
                closeBand()
                current.stacks = [ColumnStack(sections: [section], fraction: 1)]
                location[section.id] = (bands.count, 0)
                closeBand()
                continue
            }

            if current.totalFraction + section.span.fraction > 1.0001
                || current.stacks.count >= page.maxColumns {
                closeBand()
            }
            current.stacks.append(ColumnStack(sections: [section],
                                              fraction: section.span.fraction))
            location[section.id] = (bands.count, current.stacks.count - 1)
        }
        closeBand()
        return bands
    }

    // MARK: Band layout

    private struct SolvedBand {
        var placements: [PlacedSection]
        var bottom: CGFloat
        /// Sections lifted out for a full-width band of their own.
        var promoted: [ArrangedSection]
    }

    private static func layout(band: Band,
                               at top: CGFloat,
                               bandIndex: Int,
                               page: PageMetrics,
                               metrics: SectionMetrics,
                               allowPromotion: Bool = true,
                               markPromoted: Bool = false) -> SolvedBand {
        guard !band.stacks.isEmpty else {
            return SolvedBand(placements: [], bottom: top, promoted: [])
        }

        // Columns divide the width left over once the gutters are paid for,
        // in proportion to their spans. Two halves give equal columns; a half
        // beside a third gives 60/40 — which is what the plan asked for.
        let gutters = page.gutter * CGFloat(band.stacks.count - 1)
        let usable = max(page.minimumColumnWidth, page.contentWidth - gutters)
        let totalFraction = max(0.0001, band.totalFraction)

        var placements: [PlacedSection] = []
        var promoted: [ArrangedSection] = []
        var x = page.originX
        var bandBottom = top

        for (columnIndex, stack) in band.stacks.enumerated() {
            let width = (stack.fraction / totalFraction) * usable
            var y = top

            for section in stack.sections {
                let height = max(page.lineGap,
                                 metrics.height(for: section, width: width))

                // OVERFLOW PROMOTION. A column that has outgrown its share is
                // not compressed and does not spill sideways — the section is
                // lifted out and given the full measure below, the way a
                // person starts a new line when the margin closes in.
                let isMultiColumn = band.stacks.count > 1
                if allowPromotion, isMultiColumn, height > page.promotionHeight {
                    promoted.append(section)
                    continue
                }

                let snappedTop = snapUp(y, page: page)
                let snappedHeight = snapUp(snappedTop + height, page: page) - snappedTop
                placements.append(PlacedSection(
                    id: section.id,
                    frame: CGRect(x: x, y: snappedTop,
                                  width: width, height: snappedHeight),
                    block: section.block,
                    role: section.role,
                    column: columnIndex,
                    band: bandIndex,
                    wasPromoted: markPromoted
                ))
                // Sections stacked in one column are siblings, not strangers:
                // half a ruled line between them, not a full band gap.
                y = snappedTop + snappedHeight + page.lineGap * 0.5
            }
            bandBottom = max(bandBottom, y)
            x += width + page.gutter
        }

        return SolvedBand(placements: placements,
                          bottom: bandBottom,
                          promoted: promoted)
    }

    // MARK: Grid

    /// Round `y` up to the next ruled line. Everything the composer emits
    /// passes through here — it is the reason the result reads as written on
    /// the paper rather than pasted over it.
    private static func snapUp(_ y: CGFloat, page: PageMetrics) -> CGFloat {
        guard page.lineGap > 0 else { return y }
        let offset = y - page.topY
        guard offset > 0 else { return page.topY }
        return page.topY + ceil(offset / page.lineGap) * page.lineGap
    }
}
