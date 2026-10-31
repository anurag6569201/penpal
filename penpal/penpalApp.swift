//
//  penpalApp.swift
//  penpal
//
//  Created by Anurag singh on 12/07/26.
//

import SwiftUI

@main
struct penpalApp: App {
    var body: some Scene {
        WindowGroup {
            NotebookRootView()
                .tint(Pen.inkAccent)
        }
    }
}

/// Keep navigation in the view hierarchy so the welcome action immediately
/// replaces its screen. Begin reading the notebook while welcome is visible.
private struct NotebookRootView: View {
    @AppStorage("penpal.hasSeenWelcome") private var hasSeenWelcome = false
    @StateObject private var store = NotesStore.shared
    @State private var needsInitialPage = false

    var body: some View {
        Group {
            if hasSeenWelcome {
                ContentView()
            } else {
                WelcomeView {
                    needsInitialPage = true
                    hasSeenWelcome = true
                }
            }
        }
        .task(id: hasSeenWelcome) {
            guard hasSeenWelcome, needsInitialPage else { return }
            await store.waitUntilLoaded()
            guard !Task.isCancelled else { return }
            selectInitialPage()
            needsInitialPage = false
        }
    }

    private func selectInitialPage() {
        if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-selectChapter"),
           idx + 1 < ProcessInfo.processInfo.arguments.count,
           let ch = Int(ProcessInfo.processInfo.arguments[idx + 1]) {
            store.selectFolder(WelcomeGuide.folderID)
            store.selectNote(WelcomeGuide.chapterID(ch))
            return
        }
        if store.selectedNote == nil || store.selectedNote?.isDeleted == true {
            let noteInCurrentFolder = store.selectedFolder?.systemKind == .recentlyDeleted
                ? nil : store.visibleNotes().first(where: { !$0.isDeleted })
            if let note = noteInCurrentFolder ?? store.notes.first(where: { !$0.isDeleted }) {
                store.selectFolder(note.folderID)
                store.selectNote(note.id)
            } else {
                store.createNote()
            }
        }
    }
}
