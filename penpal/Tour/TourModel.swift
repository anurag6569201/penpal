//
//  TourModel.swift
//  penpal
//
//  Data models and steps for the interactive Guided Tour.
//

import SwiftUI

enum TourAnchorID: String, Hashable, CaseIterable {
    case workspace
    case undo
    case insert
    case markup
    case arrange
    case penpal
    case share
    case tour
    case more
    case capability
    case secondary
    case ask
    case camera
    case page
}

enum TourPrepare: Equatable {
    case showTools(Bool)
    case penpal(Bool)
    case capability(String)
    case toolbarSection(TourToolbarSection)
    case openSidebar(Bool)
    case showTraining(Bool)
    case showSettings(Bool)
}

enum TourToolbarSection: String, Hashable {
    case pageTools
    case history
    case document
}

/// A new identity on every step makes repeated preparation values observable
/// when somebody moves back and forth through the tour.
struct TourPreparation: Equatable {
    let id = UUID()
    let actions: [TourPrepare]
}

enum TourAdvance: Equatable {
    case next
    case event(TourEvent)
    case eventOrNext(TourEvent)
}

struct TourStep: Identifiable, Equatable {
    var id: String
    var anchor: TourAnchorID?
    var title: String
    var body: String
    var prepare: [TourPrepare]
    var advance: TourAdvance
    var tryItPrompt: String?

    static let allSteps: [TourStep] = [
        TourStep(
            id: "welcome",
            anchor: nil,
            title: "One page. Everything Penpal.",
            body: "This is your permanent thinking space. Write, solve, sketch, build, and ask for help without leaving the page. The tour lets you try the important parts for real.",
            prepare: [.showTools(false), .penpal(true)],
            advance: .next
        ),
        TourStep(
            id: "surface",
            anchor: .page,
            title: "Write anywhere",
            body: "Use Apple Pencil or your finger on this infinite page. Your work is saved automatically, and Penpal answers directly beneath it in ink.",
            prepare: [],
            advance: .next,
            tryItPrompt: "Write a word in the highlighted space, then tap Next"
        ),
        TourStep(
            id: "markup",
            anchor: .markup,
            title: "Choose your pen",
            body: "The pen-tip button opens the native ink tray with pens, pencil, highlighter, eraser, colours, and ruler.",
            prepare: [.toolbarSection(.pageTools), .showTools(true)],
            advance: .next
        ),
        TourStep(
            id: "undo",
            anchor: .undo,
            title: "Undo whole ideas",
            body: "Undo and redo handle your strokes normally, while a generated Penpal answer, graph, or sketch reverses as one clean action.",
            prepare: [.toolbarSection(.history), .showTools(false)],
            advance: .next
        ),
        TourStep(
            id: "penpal_button",
            anchor: .penpal,
            title: "Bring Penpal onto the page",
            body: "The signature button shows or hides Penpal's assistant dock. Tap it now to bring the controls back.",
            prepare: [.toolbarSection(.pageTools), .penpal(false)],
            advance: .eventOrNext(.penpalToggled),
            tryItPrompt: "Tap the signature button to continue"
        ),
        TourStep(
            id: "capability",
            anchor: .capability,
            title: "Choose the kind of help",
            body: "This menu changes Penpal between Companion, Mathematician, Interactive builder, Illustrator, Language Partner, Debate Partner, and whole-page Arranger.",
            prepare: [.penpal(true), .capability("companion")],
            advance: .next
        ),
        TourStep(
            id: "secondary",
            anchor: .secondary,
            title: "Tune the response",
            body: "The next control adapts to the capability: choose a companion mood, maths detail, illustration quality, or practice language.",
            prepare: [.penpal(true), .capability("companion")],
            advance: .next
        ),
        TourStep(
            id: "ask",
            anchor: .ask,
            title: "Ask when you are ready",
            body: "Write a question, then tap Ask Penpal. A pause never sends unfinished thoughts; you stay in control.",
            prepare: [.penpal(true)],
            advance: .eventOrNext(.askTapped),
            tryItPrompt: "Write a short question and tap Ask, or tap Next"
        ),
        TourStep(
            id: "box_gesture",
            anchor: .page,
            title: "Box anything to send it",
            body: "Write a tiny prompt inside the highlighted area, then draw a rectangle around it. Boxing is the fast gesture version of Ask.",
            prepare: [.penpal(true), .capability("companion")],
            advance: .eventOrNext(.boxDrawn),
            tryItPrompt: "Write ‘hello’, box it, or tap Next"
        ),
        TourStep(
            id: "strike_gesture",
            anchor: .page,
            title: "Strike to erase",
            body: "Write a word, then draw one horizontal line through it. Penpal removes the word and the strike together; Undo brings both back.",
            prepare: [.penpal(true)],
            advance: .eventOrNext(.strikeDone),
            tryItPrompt: "Write a word and strike through it, or tap Next"
        ),
        TourStep(
            id: "equals_math",
            anchor: .page,
            title: "Maths answers itself",
            body: "Write a calculation ending in = and pause. Penpal recognises it locally and offers the answer without a cloud request.",
            prepare: [.toolbarSection(.pageTools), .penpal(false)],
            advance: .eventOrNext(.equalsSolved),
            tryItPrompt: "Try 12 × 7 =, or tap Next"
        ),
        TourStep(
            id: "insert_blocks",
            anchor: .insert,
            title: "Put live things on paper",
            body: "Insert adds photos, interactive widgets, diagrams, text, tables, and checklists behind the ink so you can annotate over them.",
            prepare: [.toolbarSection(.pageTools), .penpal(false)],
            advance: .next
        ),
        TourStep(
            id: "arrange",
            anchor: .arrange,
            title: "Arrange the page",
            body: "Arrange mode lets you move, resize, and edit inserted blocks while keeping handwriting safely out of the way.",
            prepare: [.toolbarSection(.pageTools), .penpal(false)],
            advance: .next
        ),
        TourStep(
            id: "camera",
            anchor: .camera,
            title: "Bring in the outside world",
            body: "With Penpal open, use the camera to ask about a worksheet, diagram, or photo. Illustrator can trace a photo back into editable ink.",
            prepare: [.penpal(true)],
            advance: .next
        ),
        TourStep(
            id: "make_it_yours",
            anchor: .more,
            title: "Make the writing yours",
            body: "The more menu contains handwriting training, settings, spaced practice, and Add Writing Space when you need another screen below.",
            prepare: [.toolbarSection(.document), .penpal(true)],
            advance: .next
        ),
        TourStep(
            id: "training",
            anchor: nil,
            title: "Teach Penpal your hand",
            body: "Training captures your real letters, words, joins, maths symbols, and punctuation so replies can be written in your own style.",
            prepare: [.openSidebar(false), .showTraining(true)],
            advance: .next
        ),
        TourStep(
            id: "settings",
            anchor: nil,
            title: "Shape how Penpal responds",
            body: "Settings controls writing style, paper, response behaviour, privacy, backups, and the connection to the Penpal brain.",
            prepare: [.showTraining(false), .showSettings(true)],
            advance: .next
        ),
        TourStep(
            id: "workspace_library",
            anchor: .workspace,
            title: "Your pages are still close",
            body: "Tap the Penpal workspace badge to open the sidebar whenever you want an older page or folder. It stays out of the way until you ask for it.",
            prepare: [.showSettings(false), .openSidebar(false), .toolbarSection(.pageTools)],
            advance: .eventOrNext(.workspaceOpened),
            tryItPrompt: "Tap Penpal workspace to open the sidebar, or tap Next"
        ),
        TourStep(
            id: "finish",
            anchor: .share,
            title: "Your workspace is ready",
            body: "Share exports the current page. Finish removes the tour button and leaves only the tools you use. Now write something real and let Penpal meet you there.",
            prepare: [.openSidebar(false), .toolbarSection(.document), .showTools(false), .penpal(true)],
            advance: .next
        )
    ]
}
