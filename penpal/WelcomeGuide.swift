//
//  WelcomeGuide.swift
//  penpal
//
//  The "Penpal Guide" — a folder of real Penpal pages that teach the product
//  by being looked at.
//
//  Why pages and not a carousel: Penpal is a notebook, so the most honest
//  demonstration is a notebook page. Every chapter is built from the same
//  primitives a user's own pages use (text, table, checklist, diagram and
//  live code blocks), so what the guide shows is literally what the app can
//  put on paper.
//
//  The gesture "simulations" are self-contained SVG/SMIL animations inside
//  code blocks: a ghost pencil writes, boxes, underlines and strikes on a
//  loop, and Penpal's answer appears in its accent ink. They are offline,
//  free, never touch the user's ink and never call the brain. Under Reduce
//  Motion each one freezes on its finished frame.
//
//  Chapters use fixed IDs so "Restore Penpal Guide" can replace them in place
//  and the tour can recognise the Start page.
//

import Foundation
import CoreGraphics
import PencilKit

enum WelcomeGuide {

    // MARK: - Identity

    static let folderName = "Penpal Guide"
    static let tag = "Penpal Guide"
    static let folderID = UUID(uuidString: "5E1C0A00-0000-4000-8000-000000000000")!
    static let startNoteID = UUID(uuidString: "5E1C0A00-0000-4000-8000-000000000001")!

    nonisolated static func chapterID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "5E1C0A00-0000-4000-8000-%012d", index))!
    }

    nonisolated static var allNoteIDs: Set<UUID> { Set((1...6).map(chapterID)) }

    nonisolated static func isGuideNote(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return allNoteIDs.contains(id)
    }

    /// The legacy seed was a single text-only note that rendered as a blank
    /// page. Only an untouched one is ever replaced.
    static func isPristineLegacyWelcome(_ note: Note) -> Bool {
        note.title == "Welcome to Penpal Notes"
            && note.drawing.strokes.isEmpty
            && (note.codeBlocks ?? []).isEmpty
            && (note.replyInks ?? []).isEmpty
            && (note.typedTexts ?? []).isEmpty
            && note.attachments.isEmpty
    }

    static func makeFolder(sortOrder: Int = 0) -> NoteFolder {
        NoteFolder(id: folderID, name: folderName, isExpanded: true, sortOrder: sortOrder)
    }

    struct ChapterContent {
        var blocks: [PageBlock]
        var drawing: PKDrawing
    }

    private static var defaultInkColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 236/255, green: 234/255, blue: 228/255, alpha: 1.0)
                : UIColor(red: 26/255, green: 43/255, blue: 42/255, alpha: 1.0)
        }
    }

    @MainActor
    static func renderHandwriting(
        _ text: String,
        at origin: CGPoint,
        xHeight: CGFloat = 20,
        color: UIColor = defaultInkColor,
        weight: Double = 0.55,
        lineGap: CGFloat = 32,
        maxX: CGFloat = blockX + blockWidth - 160
    ) -> [PKStroke] {
        let sequence = StrokeFont.layoutSequence(
            text: text,
            origin: origin,
            xHeight: xHeight,
            maxX: maxX,
            lineGap: lineGap,
            maxY: origin.y + 400,
            messiness: 0.06,
            useUserHand: false,
            settings: .shared,
            allowSynthesis: false
        )
        let baseWidth = ReplyInkStyle.baseWidth(xHeight: xHeight, weight: weight)
        let prepared = ReplyInkStyle.prepare(sequence.strokes, baseWidth: baseWidth)
        return prepared.compactMap { stroke in
            let smoothed = HandwritingRenderer.smoothed(stroke, amount: 0.25)
            return ReplyInkStyle.pencilStroke(from: smoothed, baseWidth: baseWidth, color: color)
        }
    }

    /// All chapters, Start page first. Creation dates descend so the library
    /// (newest-first) lists them in reading order.
    @MainActor
    static func makeNotes(folderID: UUID = WelcomeGuide.folderID, now: Date = .now) -> [Note] {
        let chapters: [(title: String, body: String, content: ChapterContent)] = [
            ("Start here",
             "Welcome to Penpal — a notebook that writes back. Take the tour or browse this guide.",
             startHere()),
            ("1 · Talk to Penpal",
             "Turn on Penpal, write, then tap Ask or draw a box. Seven capabilities, one pen.",
             talkToPenpal()),
            ("2 · The secret gestures",
             "Box to send, double underline to check, strike to delete, = for instant maths.",
             gestures()),
            ("3 · Maths & graphs",
             "Instant answers, step-by-step working, graphs drawn in ink and practice from mistakes.",
             maths()),
            ("4 · Build on the page",
             "Live blocks — widgets, diagrams, tables, checklists and media — that sit behind your ink.",
             buildOnThePage()),
            ("5 · Make it yours",
             "Teach Penpal your handwriting, share the iPad, organise, export and back up.",
             makeItYours()),
        ]
        return chapters.enumerated().map { index, chapter in
            let created = now.addingTimeInterval(-Double(index))
            return Note(id: chapterID(index + 1),
                        folderID: folderID,
                        title: chapter.title,
                        body: chapter.body,
                        drawingData: chapter.content.drawing.dataRepresentation(),
                        paperWidth: pageWidth,
                        codeBlocks: chapter.content.blocks,
                        createdAt: created,
                        modifiedAt: created,
                        tags: [tag])
        }
    }

    // MARK: - Layout

    private static let pageWidth: CGFloat = 768
    private static let blockX: CGFloat = 48
    private static let blockWidth: CGFloat = 672

    /// Stacks blocks down the page, clear of the floating toolbar.
    private struct Column {
        var y: CGFloat = 92
        var blocks: [PageBlock] = []
        var strokes: [PKStroke] = []

        var content: ChapterContent {
            ChapterContent(blocks: blocks, drawing: PKDrawing(strokes: strokes))
        }

        mutating func add(_ html: String, _ kind: PageBlockKind, height: CGFloat, gap: CGFloat = 22) {
            blocks.append(PageBlock(html: html, kind: kind,
                                    x: WelcomeGuide.blockX, y: y,
                                    width: WelcomeGuide.blockWidth, height: height))
            y += height + gap
        }

        mutating func text(_ inner: String, variant: String = "", height: CGFloat) {
            add(WelcomeGuide.textBlock(inner, variant: variant), .text, height: height)
        }

        mutating func sim(_ html: String, svgHeight: CGFloat) {
            add(html, .code, height: svgHeight + 74)
        }

        @MainActor
        mutating func tryPad(badge: String = "TRY IN THIS SPACE",
                             title: String,
                             desc: String,
                             handwritten: String? = nil,
                             xHeight: CGFloat = 20,
                             subHint: String? = nil,
                             padHeight: CGFloat = 64,
                             height: CGFloat = 175) {
            let cardY = y
            add(WelcomeGuide.tryPadBlockHTML(badge: badge, title: title, desc: desc,
                                            subHint: subHint, padHeight: padHeight),
                .code, height: height)

            if let handwritten, !handwritten.isEmpty {
                let lineCount = handwritten.components(separatedBy: "\n").count
                let inkY: CGFloat
                if lineCount > 1 {
                    inkY = cardY + 124
                } else {
                    inkY = cardY + 128
                }
                let padStrokes = WelcomeGuide.renderHandwriting(
                    handwritten,
                    at: CGPoint(x: WelcomeGuide.blockX + 34, y: inkY),
                    xHeight: xHeight,
                    color: WelcomeGuide.defaultInkColor,
                    lineGap: 32
                )
                strokes.append(contentsOf: padStrokes)
            }
        }
    }

    // MARK: - Chapters

    @MainActor
    private static func startHere() -> ChapterContent {
        var c = Column()
        c.text("""
        <p style="font-size:12px;letter-spacing:2px;font-weight:600;color:#1B5D56;margin:0 0 6px">WELCOME</p>
        <h1 style="font-family:'New York',ui-serif,Georgia,serif;font-size:36px;font-weight:600;margin:0 0 10px">Welcome to Penpal</h1>
        <p style="font-size:17px;margin:0">A notebook that writes back. Write with your pen — Penpal reads it, thinks with you, and answers on the page in handwriting. With a little training, <b>your</b> handwriting.</p>
        """, height: 190)
        c.sim(heroSim, svgHeight: 250)
        c.text("""
        <h3>Two ways to learn Penpal</h3>
        <ul>
        <li><b>Take the tour</b> — tap <i>Take the tour</i> at the bottom of this page (or ⋯ → Take the Tour). Each control lights up, one at a time, with a short explanation.</li>
        <li><b>Browse this guide</b> — every page in the <i>Penpal Guide</i> folder shows a feature working on a loop. Open the sidebar (top-left) to find them.</li>
        </ul>
        """, variant: "callout-tip", height: 230)
        c.add(CodedPaper.checklistBlockHTML(from: """
        Turn on Penpal with the signature button
        Write a question, then tap Ask Penpal
        Draw a box around writing to send it
        Write 12 × 7 = and pause
        Teach Penpal your handwriting (⋯ → Train Handwriting)
        """), .checklist, height: 250)
        c.add(CodedPaper.tableBlockHTML(from: """
        Guide page | What you'll see
        1 · Talk to Penpal | The seven capabilities and how to ask
        2 · The secret gestures | Box, double underline, strike-through and =
        3 · Maths & graphs | Instant answers, working, ink graphs, practice
        4 · Build on the page | Live widgets, diagrams, tables and media
        5 · Make it yours | Your handwriting, profiles, export and backup
        """), .table, height: 290)
        return c.content
    }

    @MainActor
    private static func talkToPenpal() -> ChapterContent {
        var c = Column()
        c.text("""
        <p style="font-size:12px;letter-spacing:2px;font-weight:600;color:#1B5D56;margin:0 0 6px">CHAPTER 1</p>
        <h2>Talk to Penpal</h2>
        <ol>
        <li>Tap the <b>signature</b> button in the toolbar to turn on Penpal mode.</li>
        <li>Write anything with your pen — a question, a problem, a thought.</li>
        <li>Tap <b>Ask Penpal</b>, or draw a <b>box</b> around what you wrote. Penpal answers on the next line, in ink.</li>
        </ol>
        """, height: 250)
        c.sim(capabilitySim, svgHeight: 140)
        c.tryPad(title: "Your First Chat",
                 desc: "Turn on Penpal (signature button in toolbar), then tap Ask Penpal or draw a box around this handwritten question with your pen:",
                 handwritten: "How do I start my essay?",
                 subHint: "← Tap Ask or draw a box",
                 height: 175)
        c.add(CodedPaper.tableBlockHTML(from: """
        Capability | Best for | Try writing
        Companion | Thinking out loud, a warm chat | How do I start my essay?
        Mathematician | Solving and checking maths | Solve 3x + 5 = 17
        Interactive | Building live widgets on the page | A timer for 25 minutes
        Illustrator | Sketches drawn in ink | Draw a lighthouse
        Language Partner | Practising Spanish, French and more | ¿Qué hiciste hoy?
        Debate Partner | Testing an argument | Homework should be banned
        Arranger | Composing a whole page at once | A revision page on cells
        """), .table, height: 420)
        c.text("""
        <h3>The second control changes with the capability</h3>
        <ul>
        <li><b>Companion</b> — a mood: Warm, Playful, Thoughtful, Coach, or one you describe.</li>
        <li><b>Mathematician</b> — how much working: Answer only, Compact, Full working, Proof.</li>
        <li><b>Illustrator</b> — Quick, Balanced or Detailed sketches.</li>
        <li><b>Language Partner</b> — the language you are practising.</li>
        </ul>
        <p>The <b>camera</b> button lets Penpal look at a photo — and in Illustrator it traces the photo as ink.</p>
        """, variant: "callout-note", height: 290)
        c.text("""
        <h3>Nothing is sent until you ask</h3>
        <p>Penpal never replies just because you paused. Only <b>Ask</b> or a drawn <b>box</b> sends your writing, so you can stop, think and fix a letter without a half-finished question going anywhere.</p>
        """, variant: "callout-tip", height: 160)
        return c.content
    }

    @MainActor
    private static func gestures() -> ChapterContent {
        var c = Column()
        c.text("""
        <p style="font-size:12px;letter-spacing:2px;font-weight:600;color:#1B5D56;margin:0 0 6px">CHAPTER 2</p>
        <h2>The secret gestures</h2>
        <p>Penpal understands natural pen marks. For each gesture below: watch how the ghost pencil does it, then <b>interact with the live handwriting in the practice pad directly underneath</b>!</p>
        """, height: 170)

        // 1. Box Gesture
        c.sim(boxSim, svgHeight: 230)
        c.tryPad(title: "1 · Try the Box Gesture",
                 desc: "Draw a rectangular box around this handwritten prompt with your pen or finger to send it to Penpal:",
                 handwritten: "What is 15% of 80?",
                 subHint: "← Draw a box around this prompt",
                 height: 175)

        // 2. Double Underline
        c.sim(checkSim, svgHeight: 250)
        c.tryPad(title: "2 · Try Double Underline to Check",
                 desc: "Double-underline with two quick horizontal strokes underneath 'x = 5' to check your working line-by-line:",
                 handwritten: "2x + 6 = 16\n2x = 10\nx = 5",
                 xHeight: 18,
                 subHint: "← Double-underline under x = 5",
                 padHeight: 110,
                 height: 225)

        // 3. Strike-Through
        c.sim(strikeSim, svgHeight: 170)
        c.tryPad(title: "3 · Try Strike-Through Delete",
                 desc: "Draw a single quick horizontal stroke across 'mistake' (or the whole line) to delete it without switching tools:",
                 handwritten: "Delete this mistake",
                 subHint: "← Strike through 'mistake'",
                 height: 175)

        // 4. Instant Maths =
        c.sim(equalsSim, svgHeight: 220)
        c.tryPad(title: "4 · Try Instant On-Device Solve",
                 desc: "Handwritten '25 × 4' is ready for you. Write '=' right after it on the ruled line and pause for 1 second:",
                 handwritten: "25 × 4",
                 subHint: "← Write '=' & pause 1s",
                 height: 175)

        return c.content
    }

    @MainActor
    private static func maths() -> ChapterContent {
        var c = Column()
        c.text("""
        <p style="font-size:12px;letter-spacing:2px;font-weight:600;color:#1B5D56;margin:0 0 6px">CHAPTER 3</p>
        <h2>Maths &amp; graphs</h2>
        <p>Write <b>12 × 7 =</b> and pause for an instant, on-device answer. Switch to <b>Mathematician</b> for real working, and write <b>plot</b> before a function to have it drawn as ink.</p>
        """, height: 180)
        c.sim(graphSim, svgHeight: 260)
        c.tryPad(title: "Instant Equation Solver",
                 desc: "Write '=' after this equation or write another calculation on the ruled line and pause for 1 second to see the answer written in ink:",
                 handwritten: "3x + 5 = 26",
                 subHint: "← Double-underline or write =",
                 height: 175)
        c.add(CodedPaper.tableBlockHTML(from: """
        Math detail | What Penpal writes
        Answer only | Just the result
        Compact steps | The key moves, nothing extra
        Full working | Every line, the way a teacher would
        Proof | A formal, justified argument
        """), .table, height: 250)
        c.text("""
        <h3>Your mistakes become practice</h3>
        <ul>
        <li><b>Double underline</b> your working and Penpal marks each line ✓ or ✗.</li>
        <li>Lines you got wrong come back as fresh problems, spaced over days — look for <b>⋯ → Practice</b> when something is due.</li>
        <li>If Penpal misreads a digit, tap the expression on the Solve chip to correct it. It learns how <i>you</i> write that digit.</li>
        </ul>
        """, variant: "callout-note", height: 250)
        return c.content
    }

    @MainActor
    private static func buildOnThePage() -> ChapterContent {
        var c = Column()
        c.text("""
        <p style="font-size:12px;letter-spacing:2px;font-weight:600;color:#1B5D56;margin:0 0 6px">CHAPTER 4</p>
        <h2>Build on the page</h2>
        <p>Blocks are live pieces of the web that sit <b>behind</b> your ink — so you can annotate right on top of them. Add one from the 📎 menu. Tap a block with your finger to use it; the slider below is live.</p>
        """, height: 190)
        c.add(waveWidget, .code, height: 320)
        c.tryPad(title: "Annotate Over Live Widgets",
                 desc: "Adjust the frequency and amplitude sliders with your finger, then pick up your Apple Pencil and draw notes, arrows or formulas directly over the canvas:",
                 handwritten: "Wave amplitude = 0.70",
                 subHint: "← Finger moves, pen draws",
                 height: 175)
        c.add("""
        <div id="penpal-content">
        <style>
          html, body { margin: 0; min-height: 100%; font-family: -apple-system, sans-serif; }
        </style>
        <pre class="mermaid" data-penpal-kind="mermaid">flowchart LR
          A[You write] --> B{Ask or box}
          B --> C[Penpal reads your ink]
          C --> D[Reply in your hand]
          D --> A</pre>
        </div>
        """, .mermaid, height: 230)
        c.add(CodedPaper.checklistBlockHTML(from: """
        Code block — any HTML, CSS and JavaScript
        Diagram — flowcharts and mind maps
        Text — headings, callouts and lists
        Table — like the ones in this guide
        Checklist — tick these!
        Attachment — images, video, audio or a YouTube link
        """), .checklist, height: 300)
        c.text("""
        <h3>Arrange, Studio and coded paper</h3>
        <ul>
        <li>Tap the <b>dashed square</b> in the toolbar to Arrange: move, resize or delete blocks.</li>
        <li>Open a block in <b>Block Studio</b> for its full controls and its source code.</li>
        <li>Want the whole page to be code? <b>New Note ▸ New Coded Paper</b>.</li>
        <li>The <b>Arranger</b> capability composes a whole page of text, graphs and blocks from one request.</li>
        </ul>
        """, variant: "callout-note", height: 250)
        return c.content
    }

    @MainActor
    private static func makeItYours() -> ChapterContent {
        var c = Column()
        c.text("""
        <p style="font-size:12px;letter-spacing:2px;font-weight:600;color:#1B5D56;margin:0 0 6px">CHAPTER 5</p>
        <h2>Make it yours</h2>
        <p>Penpal can answer in <b>your own handwriting</b> — your letters, your joins, even your rhythm.</p>
        <ol>
        <li>Open <b>⋯ → Train Handwriting</b>.</li>
        <li>Write the words, letters, joins and digits it asks for. Each one keeps up to three samples, for natural variation.</li>
        <li>Your next reply is written in your hand. Tap 👍 or 👎 when asked — Penpal tunes itself to look more like you.</li>
        </ol>
        """, height: 300)
        c.add(CodedPaper.tableBlockHTML(from: """
        Feature | Where to find it
        Handwriting profiles — several people, one iPad | Penpal Settings
        Insights — your slant, pressure and speed | Penpal Settings
        Reply ink colour, weight and size | Penpal Settings
        Apple Pencil only (finger scrolls) | Penpal Settings
        Search your handwriting | Sidebar → Search
        Tags and pinning | Sidebar → note menu
        Export a page with its paper | Share button
        Back up the whole notebook | Penpal Settings → Notes & recovery
        """), .table, height: 400)
        c.text("""
        <h3>You're ready</h3>
        <p>Make a new note with the ✎ button and start writing. You can take the tour again any time from <b>⋯ → Take the Tour</b>, and bring this guide back from <b>⋯ → Restore Penpal Guide</b>.</p>
        """, variant: "callout-tip", height: 170)
        return c.content
    }

    // MARK: - Text blocks

    static func textBlock(_ inner: String, variant: String = "") -> String {
        let placeholder = "<h3>Text block</h3><p>Enter Arrange mode to format this text — styles, colour, lists, callouts and more.</p>"
        var html = CodedPaper.textBlockHTML
        guard html.contains(placeholder) else {
            // Template changed — still produce a valid text block.
            return """
            <div id="penpal-content"><section class="note \(variant)" data-penpal-kind="text" data-penpal-editable="true">\(inner)</section></div>
            """
        }
        html = html.replacingOccurrences(of: placeholder, with: inner)
        if !variant.isEmpty {
            html = html.replacingOccurrences(of: "class=\"note\" data-penpal-kind",
                                             with: "class=\"note \(variant)\" data-penpal-kind")
        }
        return html
    }

    // MARK: - Try In This Space Blocks

    static func tryPadBlockHTML(
        badge: String = "TRY IN THIS SPACE",
        title: String,
        desc: String,
        subHint: String? = nil,
        padHeight: CGFloat = 64
    ) -> String {
        """
        <div id="penpal-content">
        <style>
          html, body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #252530; background: transparent; }
          .try-card {
            border: 1.5px solid rgba(27, 93, 86, 0.28);
            background: rgba(27, 93, 86, 0.035);
            border-radius: 14px;
            padding: 16px 20px;
            box-sizing: border-box;
          }
          .try-head {
            display: flex;
            align-items: center;
            gap: 10px;
            margin-bottom: 8px;
          }
          .try-badge {
            background: #1B5D56;
            color: #FFFFFF;
            font-size: 11px;
            font-weight: 700;
            padding: 3px 8px;
            border-radius: 6px;
            letter-spacing: 1px;
          }
          .try-title {
            font-size: 15px;
            font-weight: 600;
            color: #1B5D56;
          }
          .try-desc {
            font-size: 14px;
            color: #4A4A58;
            margin: 0 0 12px;
            line-height: 1.4;
          }
          .try-pad {
            position: relative;
            background: rgba(255, 255, 255, 0.7);
            border: 2px dashed rgba(27, 93, 86, 0.35);
            border-radius: 10px;
            padding: 10px 16px;
            min-height: \(Int(padHeight))px;
            display: flex;
            align-items: flex-start;
            justify-content: flex-end;
            box-sizing: border-box;
            background-image: linear-gradient(rgba(27, 93, 86, 0.08) 1px, transparent 1px);
            background-size: 100% 32px;
            background-position: 0 40px;
          }
          .try-subhint {
            font-size: 12px;
            font-style: italic;
            color: #1B5D56;
            background: rgba(27, 93, 86, 0.08);
            border: 1px solid rgba(27, 93, 86, 0.2);
            padding: 3px 10px;
            border-radius: 6px;
            font-weight: 600;
            white-space: nowrap;
          }
          @media (prefers-color-scheme: dark) {
            html, body { color: #ECECF0; }
            .try-card { border-color: rgba(90, 190, 175, 0.35); background: rgba(90, 190, 175, 0.06); }
            .try-title { color: #62C4B7; }
            .try-desc { color: #C7C7D2; }
            .try-pad {
              background: rgba(30, 32, 40, 0.6);
              border-color: rgba(90, 190, 175, 0.45);
              background-image: linear-gradient(rgba(255, 255, 255, 0.06) 1px, transparent 1px);
            }
            .try-subhint {
              color: #62C4B7;
              background: rgba(90, 190, 175, 0.12);
              border-color: rgba(90, 190, 175, 0.3);
            }
          }
        </style>
        <section class="try-card" data-penpal-kind="custom" data-penpal-editable="false">
          <div class="try-head">
            <span class="try-badge">\(badge)</span>
            <span class="try-title">\(title)</span>
          </div>
          <p class="try-desc">\(desc)</p>
          <div class="try-pad">
            \(subHint.map { "<div class=\"try-subhint\">\($0)</div>" } ?? "")
          </div>
        </section>
        </div>
        """
    }

    // MARK: - Simulation kit (SVG + SMIL)

    /// Every animation in a sim shares one looping clock, so timings are
    /// expressed as fractions of the cycle. That keeps the pencil, the ink it
    /// lays down and Penpal's reply perfectly in step on every repeat.
    private struct Sim {
        let dur: Double
        let height: CGFloat
        var parts: [String] = []

        init(dur: Double, height: CGFloat) {
            self.dur = dur
            self.height = height
        }

        private func f(_ v: Double) -> String { String(format: "%.3f", v) }

        func anim(_ attr: String, _ values: [String], _ times: [Double]) -> String {
            "<animate attributeName=\"\(attr)\" values=\"\(values.joined(separator: ";"))\" keyTimes=\"\(times.map(f).joined(separator: ";"))\" dur=\"\(dur)s\" repeatCount=\"indefinite\"/>"
        }

        /// Ink that draws itself along its path between `a` and `b`.
        mutating func stroke(_ d: String, _ cls: String = "", _ a: Double, _ b: Double) {
            parts.append("<path d=\"\(d)\" class=\"st \(cls)\" pathLength=\"1\" stroke-dasharray=\"1 1\" stroke-dashoffset=\"1\">"
                         + anim("stroke-dashoffset", ["1", "1", "0", "0"], [0, a, b, 1]) + "</path>")
        }

        /// Handwritten text revealed left-to-right, as if being written.
        mutating func write(_ text: String, x: Double, y: Double, width: Double,
                            cls: String = "", size: Double = 30, from a: Double, to b: Double) {
            let id = "c\(parts.count)"
            parts.append("""
            <clipPath id="\(id)"><rect x="\(f(x - 6))" y="\(f(y - size * 1.2))" height="\(f(size * 1.7))" width="0">\(anim("width", ["0", "0", f(width + 12), f(width + 12)], [0, a, b, 1]))</rect></clipPath>
            <text x="\(f(x))" y="\(f(y))" class="hand \(cls)" style="font-size:\(f(size))px" clip-path="url(#\(id))">\(text)</text>
            """)
        }

        mutating func write(_ text: String, x: Double, y: Double, width: Double,
                            _ a: Double, _ b: Double) {
            write(text, x: x, y: y, width: width, cls: "", size: 30, from: a, to: b)
        }

        mutating func write(_ text: String, x: Double, y: Double, width: Double,
                            size: Double, _ a: Double, _ b: Double) {
            write(text, x: x, y: y, width: width, cls: "", size: size, from: a, to: b)
        }

        mutating func write(_ text: String, x: Double, y: Double, width: Double,
                            _ cls: String, _ a: Double, _ b: Double) {
            write(text, x: x, y: y, width: width, cls: cls, size: 30, from: a, to: b)
        }

        mutating func write(_ text: String, x: Double, y: Double, width: Double,
                            _ cls: String, size: Double, _ a: Double, _ b: Double) {
            write(text, x: x, y: y, width: width, cls: cls, size: size, from: a, to: b)
        }

        /// The ghost pencil, visible only while it is drawing `d`.
        mutating func pencil(_ d: String, _ a: Double, _ b: Double) {
            let inA = max(0.001, a - 0.02), outB = min(0.999, b + 0.025)
            parts.append("""
            <g opacity="0">\(anim("opacity", ["0", "0", "1", "1", "0", "0"], [0, inA, a, b, outB, 1]))<g>\
            <animateMotion path="\(d)" keyPoints="0;0;1;1" keyTimes="0;\(f(a));\(f(b));1" calcMode="linear" dur="\(dur)s" repeatCount="indefinite"/>\
            <ellipse cx="3" cy="2" rx="9" ry="3" class="shadow"/>\
            <polygon points="0,0 3,-10 10,-3" class="lead"/>\
            <polygon points="3,-10 10,-3 40,-33 33,-40" class="wood"/>\
            <polygon points="33,-40 40,-33 46,-39 39,-46" class="cap"/></g></g>
            """)
        }

        /// A group that fades in at `a…b` and optionally out at `c…d`.
        mutating func appear(_ inner: String, _ a: Double, _ b: Double,
                             out: (Double, Double)? = nil) {
            let a2 = max(0.001, a)
            let values: [String], times: [Double]
            if let out {
                values = ["0", "0", "1", "1", "0", "0"]; times = [0, a2, b, out.0, out.1, 1]
            } else {
                values = ["0", "0", "1", "1"]; times = [0, a2, b, 1]
            }
            parts.append("<g opacity=\"0\">\(anim("opacity", values, times))\(inner)</g>")
        }

        mutating func raw(_ s: String) { parts.append(s) }

        /// Three ink dots — Penpal thinking — shown between `a` and `b`.
        mutating func thinking(x: Double, y: Double, _ a: Double, _ b: Double) {
            let dots = (0..<3).map { i in
                "<circle cx=\"\(f(x + Double(i) * 16))\" cy=\"\(f(y))\" r=\"4\" class=\"dot\"><animate attributeName=\"r\" values=\"3;5.5;3\" dur=\"0.75s\" begin=\"\(f(Double(i) * 0.18))s\" repeatCount=\"indefinite\"/></circle>"
            }.joined()
            appear(dots, a, a + 0.02, out: (b - 0.02, b))
        }

        func svg(still: Double, loopFade: Bool = true, rules: Bool = true) -> String {
            let h = Double(height)
            var lines = ""
            if rules {
                var y = 64.0
                while y < h - 8 { lines += "<line x1=\"0\" x2=\"640\" y1=\"\(f(y))\" y2=\"\(f(y))\" class=\"rule\"/>"; y += 48 }
            }
            let fade = loopFade ? anim("opacity", ["1", "1", "0", "0"], [0, 0.93, 0.975, 1]) : ""
            return """
            <svg viewBox="0 0 640 \(f(h))" data-still="\(f(still * dur))" xmlns="http://www.w3.org/2000/svg">\(lines)<g>\(fade)\(parts.joined())</g></svg>
            """
        }
    }

    private static let simStyle = """
    <style>
      :root { --ink:#1A2B2A; --faded:rgba(26,43,42,.62); --accent:#1B5D56; --wash:rgba(27,93,86,.10);
              --rule:rgba(26,43,42,.09); --card:#FFFDF9; --caution:#B07C2C; --positive:#2E6E4E; --onAccent:#fff; }
      @media (prefers-color-scheme: dark) {
        :root { --ink:#ECEAE4; --faded:rgba(236,234,228,.62); --accent:#7ECEB9; --wash:rgba(126,206,185,.12);
                --rule:rgba(236,234,228,.09); --card:#141317; --caution:#D9A85C; --positive:#7FBFA0; --onAccent:#0A241F; }
      }
      html, body { margin:0; background:transparent; color:var(--ink); font-family:-apple-system, sans-serif; }
      .sim { background:var(--card); border-radius:18px; padding:10px 14px 12px;
             box-shadow:0 6px 18px rgba(0,0,0,.07); }
      .sim svg { width:100%; height:auto; display:block; }
      .cap { display:flex; gap:12px; align-items:baseline; padding:6px 4px 0; font-size:14px; color:var(--faded); }
      .cap .tag { font-size:11px; letter-spacing:1.4px; font-weight:700; color:var(--accent); text-transform:uppercase; white-space:nowrap; }
      .cap b { color:var(--ink); font-weight:600; }
      .rule { stroke:var(--rule); stroke-width:1; }
      .hand { font-family:"Bradley Hand","Noteworthy","Chalkboard SE",cursive; fill:var(--ink); }
      .hand.reply { fill:var(--accent); }
      .st { fill:none; stroke:var(--ink); stroke-width:3; stroke-linecap:round; stroke-linejoin:round; }
      .st.accent { stroke:var(--accent); }
      .st.positive { stroke:var(--positive); stroke-width:3.5; }
      .st.caution { stroke:var(--caution); stroke-width:3.5; }
      .st.thin { stroke-width:2; }
      .dot { fill:var(--accent); }
      .lead { fill:var(--ink); }
      .wood { fill:var(--accent); opacity:.92; }
      .cap { }
      polygon.cap { fill:var(--faded); }
      .shadow { fill:rgba(0,0,0,.12); }
      .chip { fill:var(--card); stroke:var(--accent); stroke-opacity:.35; stroke-width:1.2; }
      .pill { fill:var(--accent); }
      .pilltext { fill:var(--onAccent); font:600 15px -apple-system, sans-serif; }
      .ui { fill:var(--ink); font:500 16px -apple-system, sans-serif; }
      .uiaccent { fill:var(--accent); font:600 16px -apple-system, sans-serif; }
      .uifaded { fill:var(--faded); font:400 15px -apple-system, sans-serif; }
      .wash { fill:var(--wash); }
      .bar { fill:var(--card); stroke:var(--rule); stroke-width:1.5; }
      .ripple { fill:var(--accent); }
    </style>
    """

    /// Freeze on the finished frame under Reduce Motion.
    private static let simScript = """
    <script>
    (function () {
      var s = document.querySelector('svg'); if (!s || !s.pauseAnimations) return;
      var m = window.matchMedia('(prefers-reduced-motion: reduce)');
      function apply() {
        if (m.matches) { s.pauseAnimations(); s.setCurrentTime(parseFloat(s.getAttribute('data-still') || '0')); }
        else { s.unpauseAnimations(); }
      }
      apply();
      if (m.addEventListener) m.addEventListener('change', apply);
    })();
    </script>
    """

    private static func simBlock(tag: String, title: String, caption: String, svg: String) -> String {
        """
        \(simStyle)
        <div class="sim" data-penpal-sim="\(tag.lowercased())">
        \(svg)
        <div class="cap"><span class="tag">\(tag)</span><span><b>\(title)</b> — \(caption)</span></div>
        </div>
        \(simScript)
        """
    }

    // MARK: - Sims

    private static var heroSim: String {
        var s = Sim(dur: 11, height: 250)
        s.write("Hi Penpal! Can you help me plan my week?", x: 34, y: 92, width: 560, size: 28, 0.03, 0.30)
        s.pencil("M34,94 C200,88 400,98 594,90", 0.03, 0.30)
        s.thinking(x: 44, y: 128, 0.33, 0.44)
        s.write("Of course! Let's start with Monday —", x: 34, y: 148, width: 520, "reply", size: 28, 0.44, 0.68)
        s.write("what matters most to you?", x: 34, y: 196, width: 360, "reply", size: 28, 0.69, 0.84)
        return simBlock(tag: "Penpal mode", title: "A notebook that writes back",
                        caption: "you write, Penpal answers on the page.",
                        svg: s.svg(still: 0.9))
    }

    private static var boxSim: String {
        var s = Sim(dur: 8, height: 230)
        let box = "M72,78 C160,72 280,74 352,80 C357,104 357,128 350,148 C260,153 160,151 74,146 C68,124 67,100 72,78"
        s.write("3x + 5 = 17", x: 90, y: 122, width: 240, 0.04, 0.26)
        s.pencil("M90,124 C150,118 240,128 330,120", 0.04, 0.26)
        s.raw("<g>" + s.anim("opacity", ["1"], [0]) + "</g>")
        s.stroke(box, "accent", 0.30, 0.48)
        s.pencil(box, 0.30, 0.48)
        s.thinking(x: 388, y: 114, 0.50, 0.62)
        s.write("3x = 12", x: 100, y: 196, width: 130, "reply", 0.63, 0.74)
        s.write("x = 4", x: 290, y: 196, width: 100, "reply", 0.76, 0.86)
        return simBlock(tag: "Box", title: "Box it to send it",
                        caption: "a loop around new writing is the same as tapping Ask, in every mode.",
                        svg: s.svg(still: 0.9))
    }

    private static var checkSim: String {
        var s = Sim(dur: 9.5, height: 250)
        s.write("2x + 3 = 11", x: 90, y: 74, width: 200, 0.03, 0.14)
        s.write("2x = 8", x: 90, y: 122, width: 120, 0.15, 0.23)
        s.write("x = 5", x: 90, y: 170, width: 100, 0.24, 0.31)
        s.pencil("M90,76 C200,70 290,80 290,72", 0.03, 0.14)
        let u1 = "M84,186 C130,183 190,188 228,184", u2 = "M86,196 C132,193 190,198 230,194"
        s.stroke(u1, "", 0.35, 0.42); s.pencil(u1, 0.35, 0.42)
        s.stroke(u2, "", 0.45, 0.52); s.pencil(u2, 0.45, 0.52)
        s.thinking(x: 260, y: 190, 0.53, 0.60)
        s.stroke("M332,62 L341,74 L360,50", "positive", 0.61, 0.65)
        s.stroke("M332,110 L341,122 L360,98", "positive", 0.66, 0.70)
        s.stroke("M332,152 L354,174 M354,152 L332,174", "caution", 0.71, 0.75)
        s.write("8 ÷ 2 = 4", x: 380, y: 172, width: 150, "reply", 0.76, 0.87)
        return simBlock(tag: "Double underline", title: "Check my work",
                        caption: "underline twice and Penpal marks every line ✓ or ✗ — with the fix.",
                        svg: s.svg(still: 0.9))
    }

    private static var strikeSim: String {
        var s = Sim(dur: 7.5, height: 170)
        let id = "sw"
        s.raw("""
        <clipPath id="\(id)"><rect x="60" y="70" height="56" width="0">\(s.anim("width", ["0", "0", "520", "520"], [0, 0.04, 0.30, 1]))</rect></clipPath>
        <g clip-path="url(#\(id))">
          <text x="70" y="110" class="hand" style="font-size:30px">Meet at the</text>
          <g>\(s.anim("opacity", ["1", "1", "0", "0"], [0, 0.52, 0.62, 1]))
            <text x="232" y="110" class="hand" style="font-size:30px">old</text></g>
          <g>\(s.anim("opacity", ["1"], [0]))
            <text x="298" y="110" class="hand" style="font-size:30px">café at 5<animateTransform attributeName="transform" type="translate" values="0,0;0,0;-60,0;-60,0" keyTimes="0;0.62;0.72;1" dur="7.5s" repeatCount="indefinite"/></text></g>
        </g>
        """)
        s.pencil("M70,112 C200,106 360,116 520,108", 0.04, 0.30)
        let strike = "M224,100 C246,96 268,99 292,95"
        s.raw("<g>" + s.anim("opacity", ["1", "1", "0", "0"], [0, 0.52, 0.62, 1]))
        s.stroke(strike, "", 0.38, 0.46)
        s.raw("</g>")
        s.pencil(strike, 0.38, 0.46)
        return simBlock(tag: "Strike-through", title: "Cross it out",
                        caption: "a line through words deletes them — no eraser needed.",
                        svg: s.svg(still: 0.85))
    }

    private static var equalsSim: String {
        var s = Sim(dur: 8, height: 220)
        s.write("12 × 7 =", x: 90, y: 160, width: 170, 0.04, 0.26)
        s.pencil("M90,162 C150,156 210,166 262,158", 0.04, 0.26)
        s.appear("""
        <rect x="80" y="62" width="214" height="44" rx="22" class="chip"/>
        <text x="102" y="90" class="ui">12 × 7</text>
        <rect x="200" y="68" width="84" height="32" rx="16" class="pill"/>
        <text x="219" y="89" class="pilltext">Solve</text>
        """, 0.32, 0.36, out: (0.56, 0.60))
        s.raw("<circle cx=\"242\" cy=\"84\" r=\"0\" class=\"ripple\" opacity=\"0\">"
              + s.anim("r", ["0", "0", "26", "26"], [0, 0.48, 0.56, 1])
              + s.anim("opacity", ["0", "0", "0.45", "0", "0"], [0, 0.479, 0.48, 0.56, 1])
              + "</circle>")
        s.raw("<text x=\"282\" y=\"160\" class=\"hand reply\" style=\"font-size:30px\" opacity=\"0\">84"
              + s.anim("opacity", ["0", "0", "0.3", "0.3", "1", "1"], [0, 0.58, 0.62, 0.70, 0.76, 1])
              + "</text>")
        return simBlock(tag: "=", title: "Instant maths",
                        caption: "end with = and pause. Penpal shows what it read; tap Solve.",
                        svg: s.svg(still: 0.85))
    }

    private static var graphSim: String {
        var s = Sim(dur: 9, height: 260)
        s.write("plot sin(x)", x: 40, y: 74, width: 190, 0.03, 0.20)
        s.pencil("M40,76 C100,70 170,80 230,72", 0.03, 0.20)
        let xAxis = "M300,150 L620,150", yAxis = "M460,40 L460,244"
        s.stroke(xAxis, "thin", 0.24, 0.31); s.pencil(xAxis, 0.24, 0.31)
        s.stroke(yAxis, "thin", 0.32, 0.39); s.pencil(yAxis, 0.32, 0.39)
        var d = ""
        var x = 310.0
        while x <= 610 {
            let y = 150 - 62 * sin((x - 460) / 30)
            d += (d.isEmpty ? "M" : " L") + String(format: "%.1f,%.1f", x, y)
            x += 4
        }
        s.stroke(d, "accent", 0.42, 0.78); s.pencil(d, 0.42, 0.78)
        s.write("y = sin x", x: 486, y: 232, width: 120, "reply", size: 24, 0.80, 0.88)
        return simBlock(tag: "Graph", title: "Graphs drawn in ink",
                        caption: "write plot and a function — Penpal draws it with the same pen, on device.",
                        svg: s.svg(still: 0.9))
    }

    private static var capabilitySim: String {
        var s = Sim(dur: 10.5, height: 140)
        let caps: [(String, String)] = [
            ("Companion", "Chats in a warm, human voice"),
            ("Mathematician", "Solves and checks maths, step by step"),
            ("Interactive", "Builds live widgets right on the page"),
            ("Illustrator", "Sketches in ink — or traces a photo"),
            ("Language Partner", "Practises a language with you"),
            ("Debate Partner", "Argues the other side, kindly"),
            ("Arranger", "Composes a whole page at once"),
        ]
        s.raw("""
        <rect x="24" y="18" width="592" height="60" rx="30" class="bar"/>
        <rect x="34" y="26" width="236" height="44" rx="22" class="wash"/>
        <rect x="430" y="26" width="140" height="44" rx="22" class="pill"/>
        <text x="452" y="54" class="pilltext">✦  Ask Penpal</text>
        <text x="585" y="55" class="uifaded">◉</text>
        """)
        let n = Double(caps.count)
        for (i, cap) in caps.enumerated() {
            let a = Double(i) / n, b = Double(i + 1) / n
            let values: [String], times: [Double]
            if i == 0 {
                values = ["1", "1", "0", "0"]; times = [0, b - 0.012, b, 1]
            } else if i == caps.count - 1 {
                values = ["0", "0", "1", "1"]; times = [0, a, a + 0.012, 1]
            } else {
                values = ["0", "0", "1", "1", "0", "0"]; times = [0, a, a + 0.012, b - 0.012, b, 1]
            }
            s.raw("""
            <g opacity="\(i == 0 ? "1" : "0")">\(s.anim("opacity", values, times))
              <text x="54" y="54" class="uiaccent">\(cap.0)</text>
              <text x="320" y="118" class="uifaded" text-anchor="middle">\(cap.1)</text>
            </g>
            """)
        }
        return simBlock(tag: "Control bar", title: "Pick who Penpal is",
                        caption: "the capability menu changes how Penpal reads and replies.",
                        svg: s.svg(still: 0.05, loopFade: false, rules: false))
    }

    /// A real, live widget: finger-operated sliders redraw a wave.
    private static let waveWidget = """
    \(simStyle)
    <style>
      .wave { background:var(--card); border-radius:18px; padding:12px 16px 14px; box-shadow:0 6px 18px rgba(0,0,0,.07); }
      .wave canvas { width:100%; height:200px; display:block; }
      .wave .row { display:flex; gap:18px; flex-wrap:wrap; font-size:14px; color:var(--faded); padding-top:6px; }
      .wave label { display:flex; align-items:center; gap:8px; flex:1; min-width:200px; }
      .wave input { flex:1; accent-color:var(--accent); }
    </style>
    <div class="wave" data-penpal-sim="live">
      <canvas id="c"></canvas>
      <div class="row">
        <label>Frequency <input id="f" type="range" min="0.5" max="5" step="0.1" value="1.6"></label>
        <label>Amplitude <input id="a" type="range" min="0.1" max="1" step="0.05" value="0.7"></label>
      </div>
      <div class="cap"><span class="tag">Live block</span><span><b>Try the sliders</b> — then write on top of the wave with your pen.</span></div>
    </div>
    <script>
    (function () {
      var c = document.getElementById('c'), g = c.getContext('2d');
      var f = document.getElementById('f'), a = document.getElementById('a');
      var t = 0, reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      function css(v) { return getComputedStyle(document.documentElement).getPropertyValue(v).trim(); }
      function draw() {
        var dpr = window.devicePixelRatio || 1;
        c.width = c.clientWidth * dpr; c.height = c.clientHeight * dpr;
        var w = c.width, h = c.height;
        g.clearRect(0, 0, w, h);
        g.strokeStyle = css('--rule'); g.lineWidth = dpr;
        g.beginPath(); g.moveTo(0, h / 2); g.lineTo(w, h / 2); g.stroke();
        g.strokeStyle = css('--accent'); g.lineWidth = 3 * dpr; g.lineCap = 'round';
        g.beginPath();
        var fr = parseFloat(f.value), am = parseFloat(a.value);
        for (var px = 0; px <= w; px += 2) {
          var x = px / w * Math.PI * 2 * fr + t;
          var py = h / 2 - Math.sin(x) * am * h * 0.42;
          px === 0 ? g.moveTo(px, py) : g.lineTo(px, py);
        }
        g.stroke();
      }
      function tick() { t += 0.03; draw(); requestAnimationFrame(tick); }
      f.addEventListener('input', draw); a.addEventListener('input', draw);
      window.addEventListener('resize', draw);
      if (reduce) { draw(); } else { tick(); }
    })();
    </script>
    """
}
