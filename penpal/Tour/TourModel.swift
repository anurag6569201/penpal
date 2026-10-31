//
//  TourModel.swift
//  penpal
//
//  Data models and steps for the interactive Guided Tour.
//

import SwiftUI

enum TourAnchorID: String, Hashable, CaseIterable {
    case sidebar
    case undo
    case insert
    case markup
    case arrange
    case penpal
    case share
    case newNote
    case more
    case capability
    case secondary
    case ask
    case camera
    case page
}

enum TourPrepare: Equatable {
    case selectGuideStart
    case selectChapter(Int)
    case showTools(Bool)
    case penpal(Bool)
    case capability(String)
    case openDrawer(Bool)
}

enum TourAdvance: Equatable {
    case next
    case event(TourEvent)
    case eventOrNext(TourEvent)
}

enum TourDemo: Equatable {
    case none
    case ghost(strokeId: String, replyText: String?)
}

struct TourStep: Identifiable, Equatable {
    var id: String
    var anchor: TourAnchorID?
    var title: String
    var body: String
    var prepare: [TourPrepare]
    var demo: TourDemo
    var advance: TourAdvance
    var tryItPrompt: String?

    static let allSteps: [TourStep] = [
        TourStep(
            id: "welcome",
            anchor: nil,
            title: "Welcome to Penpal",
            body: "A notebook that thinks and writes alongside you on paper. Let's take a quick 2-minute tour of the essentials.",
            prepare: [.selectGuideStart],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "surface",
            anchor: .page,
            title: "The Living Page",
            body: "Write freely with your Apple Pencil or finger. Penpal reads your handwriting and writes back directly on the page in ink.",
            prepare: [],
            demo: .ghost(strokeId: "hero.question", replyText: "Of course! Let's start with Monday —"),
            advance: .next
        ),
        TourStep(
            id: "markup",
            anchor: .markup,
            title: "Apple Notes Pen Tray",
            body: "Tap the pen tip to show the full system pen tray with pens, pencil, highlighter, eraser and ruler.",
            prepare: [.showTools(true)],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "undo",
            anchor: .undo,
            title: "Smart Undo & Redo",
            body: "Undo knows what Penpal did — tapping undo cleanly reverses an entire generated reply or ink graph in one step.",
            prepare: [],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "penpal_button",
            anchor: .penpal,
            title: "Turn On Penpal Mode",
            body: "Tap the signature icon to bring up Penpal's floating control bar. Try tapping it now!",
            prepare: [],
            demo: .none,
            advance: .eventOrNext(.penpalToggled),
            tryItPrompt: "Tap the signature button to continue"
        ),
        TourStep(
            id: "capability",
            anchor: .capability,
            title: "Choose Who Penpal Is",
            body: "Switch between 7 capabilities: Companion, Mathematician, Interactive widgets, Illustrator, Language Partner, Debate, or Arranger.",
            prepare: [.penpal(true)],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "secondary",
            anchor: .secondary,
            title: "Personality & Detail",
            body: "Fine-tune Penpal's voice: change Companion mood, adjust Mathematician working depth, or choose a practice language.",
            prepare: [.penpal(true)],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "ask",
            anchor: .ask,
            title: "Ask Penpal",
            body: "Write your question on the page, then tap Ask. Penpal never sends on a pause — only when you ask.",
            prepare: [.penpal(true)],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "box_gesture",
            anchor: .page,
            title: "The Box Gesture",
            body: "Instead of tapping Ask, draw a rectangular box around any writing with your pen. Penpal reads and solves the enclosed crop!",
            prepare: [.selectChapter(3), .penpal(true)],
            demo: .ghost(strokeId: "box.question", replyText: "x = 4"),
            advance: .eventOrNext(.boxDrawn),
            tryItPrompt: "Draw a box around writing to try it, or tap Next"
        ),
        TourStep(
            id: "strike_gesture",
            anchor: .page,
            title: "Strike-Through Gesture",
            body: "No need to switch to the eraser — drawing a single line across any written word immediately deletes it.",
            prepare: [.selectChapter(3)],
            demo: .ghost(strokeId: "strike.sentence", replyText: nil),
            advance: .eventOrNext(.strikeDone),
            tryItPrompt: "Strike through a word to try it, or tap Next"
        ),
        TourStep(
            id: "equals_math",
            anchor: .page,
            title: "Instant On-Device Maths",
            body: "Write any calculation ending in \"=\" (like 12 × 7 =) and pause. A confirmation chip appears to solve it instantly without leaving the device.",
            prepare: [.selectChapter(3), .penpal(false)],
            demo: .ghost(strokeId: "equals.expr", replyText: "84"),
            advance: .eventOrNext(.equalsSolved),
            tryItPrompt: "Write a calculation ending in = (e.g. 12 × 7 =) to try it, or tap Next"
        ),
        TourStep(
            id: "insert_blocks",
            anchor: .insert,
            title: "Live Page Blocks",
            body: "Tap 📎 to insert interactive widgets, diagrams, tables, checklists or videos that sit behind your ink so you can annotate over them.",
            prepare: [.penpal(false)],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "sidebar_search",
            anchor: .sidebar,
            title: "Library & Handwriting Search",
            body: "Organise folders and search not just typed text, but your actual handwritten strokes via on-device Vision recognition.",
            prepare: [],
            demo: .none,
            advance: .next
        ),
        TourStep(
            id: "more_actions",
            anchor: .more,
            title: "Make It Unmistakably Yours",
            body: "Under ⋯, tap 'Train Handwriting' to teach Penpal your own handwriting style, or access spaced practice and backups.",
            prepare: [],
            demo: .none,
            advance: .next
        )
    ]
}
