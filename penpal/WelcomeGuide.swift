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
        // 1. Hero showcase with animated vector Penpal mark, dialogue preview, and quick actions
        c.add(startHeroHTML, .code, height: 420)

        // 2. Interactive live handwriting pad - renders real PKStrokes on frame 0!
        c.tryPad(
            badge: "TRY IN THIS SPACE",
            title: "Your First Conversation",
            desc: "Turn on Penpal (signature button in toolbar), then draw a box around this handwritten prompt with your pen or tap Ask Penpal:",
            handwritten: "Hi Penpal! What can we do\ntogether?",
            subHint: "← Draw a box or tap Ask",
            padHeight: 90,
            height: 205
        )

        // 3. Interactive Guide Directory with direct chapter links
        c.add(guideDirectoryHTML, .code, height: 410)

        // 4. Getting Started Checklist
        c.add(CodedPaper.checklistBlockHTML(from: """
        Turn on Penpal with the signature button in the toolbar
        Write a question, then tap Ask Penpal or draw a box
        Write 12 × 7 = and pause for instant maths
        Teach Penpal your handwriting (⋯ → Train Handwriting)
        Take the guided tour (tap button at bottom of page)
        """), .checklist, height: 260)

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

    // MARK: - Start Here Custom Blocks

    static let vectorMarkSVGPath = "M 488.98 1120.75 C 496.30 1117.01 497.49 1114.50 497.56 1102.67 C 497.62 1093.83 497.99 1091.65 500.43 1086.00 C 509.49 1064.98 522.96 1043.30 539.89 1022.50 C 543.47 1018.10 556.36 1004.38 568.54 992.00 C 592.59 967.55 595.05 964.11 596.91 952.25 C 598.78 940.31 596.03 930.95 586.51 916.88 C 579.18 906.04 571.67 890.60 568.83 880.50 C 567.03 874.12 566.57 869.86 566.54 859.50 C 566.50 844.85 567.60 840.33 573.65 830.38 C 577.74 823.66 577.79 824.22 571.66 808.50 C 560.10 778.84 553.22 744.55 549.40 697.50 C 547.31 671.80 546.98 599.76 548.82 572.00 C 553.81 496.87 560.74 462.15 577.54 428.15 C 608.24 366.00 665.41 325.92 727.00 323.36 C 795.80 320.51 846.18 369.12 853.95 445.86 C 855.39 460.07 855.27 471.20 853.50 486.51 C 851.66 502.45 850.67 507.59 846.86 521.00 C 836.22 558.49 815.32 592.27 788.90 614.65 C 757.60 641.16 724.17 653.03 684.50 651.72 C 667.26 651.15 658.86 649.72 644.00 644.84 C 625.04 638.61 608.78 628.93 591.86 613.79 C 580.69 603.80 577.48 602.14 572.92 604.03 C 564.18 607.65 566.58 626.77 578.99 652.50 C 591.52 678.46 611.73 701.25 637.50 718.47 C 662.46 735.16 690.29 745.73 722.18 750.66 C 739.43 753.32 771.27 753.04 789.00 750.06 C 832.97 742.68 872.76 723.76 907.50 693.72 C 944.77 661.49 974.75 614.97 989.49 566.50 C 1007.99 505.70 1007.09 435.88 987.05 377.77 C 969.36 326.47 938.48 284.84 898.23 258.01 C 851.29 226.72 791.19 218.13 731.00 234.10 C 699.38 242.50 665.09 260.36 636.65 283.23 C 618.22 298.05 590.95 327.18 577.72 346.17 L 576.10 348.50 L 576.05 346.30 C 576.02 345.09 576.45 341.94 576.99 339.30 C 578.58 331.60 580.89 312.23 582.04 296.93 C 583.99 271.01 580.90 240.95 574.44 223.00 C 555.75 171.03 511.48 143.14 455.32 147.94 C 401.62 152.53 351.58 177.49 328.15 211.38 C 319.59 223.75 316.42 235.36 318.96 245.00 C 323.05 260.51 334.72 264.46 360.40 259.04 C 375.89 255.77 387.30 256.40 396.75 261.04 C 411.87 268.47 421.33 283.82 425.40 307.50 C 428.14 323.48 429.00 341.47 428.99 382.40 C 428.96 485.73 421.79 637.47 413.90 702.00 C 408.11 749.36 401.51 779.38 390.32 809.27 L 384.79 824.04 L 388.97 830.45 C 403.02 852.03 397.84 884.43 374.84 918.69 C 368.71 927.83 365.99 934.76 365.30 942.98 C 364.65 950.77 366.72 959.93 370.70 966.82 C 372.19 969.39 382.45 980.50 393.51 991.50 C 422.54 1020.38 441.28 1044.72 454.77 1071.06 C 463.27 1087.66 466.29 1096.11 464.95 1099.62 C 462.09 1107.17 465.78 1116.90 472.96 1120.70 C 478.45 1123.60 483.37 1123.62 488.98 1120.75 Z M 480.27 1088.30 C 479.59 1088.05 478.59 1086.19 478.05 1084.17 C 476.64 1078.91 475.02 1049.47 475.01 1028.91 C 475.00 1019.24 474.70 1002.45 474.34 991.61 L 473.68 971.89 L 470.52 970.57 C 461.34 966.74 455.03 956.82 455.01 946.22 C 454.99 935.72 459.82 927.63 469.18 922.46 C 476.07 918.64 486.16 918.32 492.57 921.71 C 497.08 924.09 502.93 930.11 505.67 935.19 C 508.33 940.12 508.14 952.21 505.31 957.54 C 502.78 962.32 495.76 969.04 491.44 970.82 L 488.38 972.08 L 487.19 1020.29 C 485.70 1080.01 484.69 1089.95 480.27 1088.30 Z"

    static let startHeroHTML: String = """
    <div id="penpal-content">
    <style>
      :root {
        --ink: #1A2B2A;
        --faded: rgba(26,43,42,0.68);
        --accent: #1B5D56;
        --wash: rgba(27,93,86,0.06);
        --border: rgba(27,93,86,0.18);
        --rule: rgba(26,43,42,0.08);
        --card: #FFFDF9;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --ink: #ECEAE4;
          --faded: rgba(236,234,228,0.68);
          --accent: #7ECEB9;
          --wash: rgba(126,206,185,0.08);
          --border: rgba(126,206,185,0.24);
          --rule: rgba(236,234,228,0.08);
          --card: #141317;
        }
      }
      html, body { margin: 0; background: transparent; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: var(--ink); }
      .hero-card {
        background: var(--card);
        border: 1.5px solid var(--border);
        border-radius: 20px;
        padding: 24px 26px;
        box-sizing: border-box;
        box-shadow: 0 10px 30px rgba(0,0,0,0.05);
      }
      .hero-header {
        display: flex;
        align-items: center;
        gap: 16px;
        margin-bottom: 16px;
      }
      .hero-logo-wrap {
        width: 52px;
        height: 52px;
        flex-shrink: 0;
      }
      .hero-logo-wrap svg {
        width: 100%;
        height: 100%;
        display: block;
      }
      .hero-logo-path {
        fill: var(--accent);
        transform-origin: center;
        animation: markBreathe 3s ease-in-out infinite alternate;
      }
      @keyframes markBreathe {
        0% { transform: scale(1); filter: drop-shadow(0 0 0px var(--accent)); }
        100% { transform: scale(1.035); filter: drop-shadow(0 2px 10px rgba(27,93,86,0.35)); }
      }
      .hero-title-group h1 {
        font-family: 'New York', Georgia, serif;
        font-size: 28px;
        font-weight: 600;
        margin: 0 0 3px;
        letter-spacing: -0.4px;
        line-height: 1.15;
      }
      .hero-badge {
        font-size: 11px;
        letter-spacing: 1.8px;
        font-weight: 700;
        color: var(--accent);
        text-transform: uppercase;
      }
      .hero-desc {
        font-size: 15px;
        line-height: 1.5;
        color: var(--faded);
        margin: 0 0 18px;
      }
      .dialogue-preview {
        background: var(--wash);
        border: 1px solid var(--border);
        border-radius: 14px;
        padding: 16px 20px;
        position: relative;
        background-image: linear-gradient(var(--rule) 1px, transparent 1px);
        background-size: 100% 34px;
        background-position: 0 38px;
      }
      .dialogue-row {
        margin-bottom: 12px;
      }
      .dialogue-row:last-child {
        margin-bottom: 0;
      }
      .dialogue-speaker {
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 1px;
        text-transform: uppercase;
        color: var(--faded);
        margin-bottom: 2px;
      }
      .dialogue-text {
        font-family: "Noteworthy", "Bradley Hand", cursive, -apple-system, sans-serif;
        font-size: 22px;
        line-height: 34px;
        color: var(--ink);
        margin: 0;
      }
      .dialogue-text.reply {
        color: var(--accent);
        font-weight: 600;
      }
      .hero-actions {
        display: flex;
        gap: 10px;
        margin-top: 18px;
        flex-wrap: wrap;
      }
      .btn-action {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        background: var(--accent);
        color: #fff;
        text-decoration: none;
        font-size: 14px;
        font-weight: 600;
        padding: 9px 18px;
        border-radius: 20px;
        transition: transform 0.15s ease, opacity 0.15s ease;
      }
      .btn-action.secondary {
        background: var(--wash);
        color: var(--accent);
        border: 1px solid var(--border);
      }
      @media (prefers-reduced-motion: reduce) {
        .hero-logo-path { animation: none; }
      }
    </style>
    <div class="hero-card" data-penpal-kind="custom" data-penpal-editable="false">
      <div class="hero-header">
        <div class="hero-logo-wrap">
          <svg viewBox="0 0 1254 1254">
            <path class="hero-logo-path" fill-rule="evenodd" d="\(vectorMarkSVGPath)" />
          </svg>
        </div>
        <div class="hero-title-group">
          <span class="hero-badge">INK STUDIO</span>
          <h1>Welcome to Penpal</h1>
        </div>
      </div>
      <p class="hero-desc">
        A notebook that writes back. Write naturally with your pen — Penpal reads your ink, thinks with you, and answers right on the page in handwriting. With a little training, <b>your</b> handwriting.
      </p>
      <div class="dialogue-preview">
        <div class="dialogue-row">
          <div class="dialogue-speaker">You wrote</div>
          <p class="dialogue-text">Hi Penpal! Can you help me plan my week?</p>
        </div>
        <div class="dialogue-row">
          <div class="dialogue-speaker" style="color:var(--accent);">Penpal replied in ink</div>
          <p class="dialogue-text reply">Of course! Let's start with Monday — what matters most to you?</p>
        </div>
      </div>
      <div class="hero-actions">
        <a href="penpal://tour" class="btn-action">✦ Take the Tour</a>
        <a href="penpal://chapter/1" class="btn-action secondary">1 · Talk to Penpal →</a>
        <a href="penpal://chapter/2" class="btn-action secondary">2 · Secret Gestures →</a>
      </div>
    </div>
    </div>
    """

    static let guideDirectoryHTML: String = """
    <div id="penpal-content">
    <style>
      :root {
        --ink: #1A2B2A;
        --faded: rgba(26,43,42,0.68);
        --accent: #1B5D56;
        --wash: rgba(27,93,86,0.06);
        --border: rgba(27,93,86,0.18);
        --card: #FFFDF9;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --ink: #ECEAE4;
          --faded: rgba(236,234,228,0.68);
          --accent: #7ECEB9;
          --wash: rgba(126,206,185,0.08);
          --border: rgba(126,206,185,0.24);
          --card: #141317;
        }
      }
      html, body { margin: 0; background: transparent; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: var(--ink); }
      .dir-card {
        background: var(--card);
        border: 1.5px solid var(--border);
        border-radius: 20px;
        padding: 24px 26px;
        box-sizing: border-box;
        box-shadow: 0 10px 30px rgba(0,0,0,0.04);
      }
      .dir-title { font-family: 'New York', Georgia, serif; font-size: 20px; font-weight: 600; margin: 0 0 14px; }
      .dir-grid { display: flex; flex-direction: column; gap: 8px; }
      .dir-item {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 12px 16px;
        background: var(--wash);
        border: 1px solid var(--border);
        border-radius: 12px;
        text-decoration: none;
        color: inherit;
        transition: background 0.15s ease;
      }
      .dir-item:active { background: rgba(27,93,86,0.12); }
      .dir-num { font-weight: 700; color: var(--accent); margin-right: 10px; font-size: 14px; }
      .dir-text { flex: 1; }
      .dir-name { font-weight: 600; font-size: 15px; margin-bottom: 2px; }
      .dir-desc { font-size: 13px; color: var(--faded); }
      .dir-arrow { color: var(--accent); font-weight: 700; font-size: 16px; margin-left: 12px; }
    </style>
    <div class="dir-card" data-penpal-kind="custom" data-penpal-editable="false">
      <div class="dir-title">Explore the Penpal Guide</div>
      <div class="dir-grid">
        <a href="penpal://chapter/1" class="dir-item">
          <div class="dir-text">
            <div class="dir-name"><span class="dir-num">1</span>Talk to Penpal</div>
            <div class="dir-desc">The seven capabilities and how to ask with your pen</div>
          </div>
          <div class="dir-arrow">→</div>
        </a>
        <a href="penpal://chapter/2" class="dir-item">
          <div class="dir-text">
            <div class="dir-name"><span class="dir-num">2</span>The Secret Gestures</div>
            <div class="dir-desc">Box to send, double underline to check, strike to delete, and =</div>
          </div>
          <div class="dir-arrow">→</div>
        </a>
        <a href="penpal://chapter/3" class="dir-item">
          <div class="dir-text">
            <div class="dir-name"><span class="dir-num">3</span>Maths & Graphs</div>
            <div class="dir-desc">Instant answers, working steps, ink graphs, practice from mistakes</div>
          </div>
          <div class="dir-arrow">→</div>
        </a>
        <a href="penpal://chapter/4" class="dir-item">
          <div class="dir-text">
            <div class="dir-name"><span class="dir-num">4</span>Build on the Page</div>
            <div class="dir-desc">Live widgets, flowcharts, tables, checklists, and media</div>
          </div>
          <div class="dir-arrow">→</div>
        </a>
        <a href="penpal://chapter/5" class="dir-item">
          <div class="dir-text">
            <div class="dir-name"><span class="dir-num">5</span>Make It Yours</div>
            <div class="dir-desc">Train Penpal your handwriting, profiles, backup and export</div>
          </div>
          <div class="dir-arrow">→</div>
        </a>
      </div>
    </div>
    </div>
    """

    // MARK: - Sims

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
