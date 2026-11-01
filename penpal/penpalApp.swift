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
            WorkspaceRootView()
                .tint(Pen.inkAccent)
        }
    }
}

/// Penpal is one living surface, not a notebook browser. NotesStore remains the
/// durable storage engine, but the product always opens the same workspace and
/// teaches everything else in context through the interactive tour.
private struct WorkspaceRootView: View {
    @AppStorage("penpal.workspace.didOfferTour.v1") private var didOfferTour = false
    @StateObject private var store = NotesStore.shared
    @StateObject private var tour = TourCoordinator.shared

    var body: some View {
        ContentView()
        .task {
            await store.waitUntilLoaded()
            guard !Task.isCancelled else { return }
            store.openWorkspace()

            if ProcessInfo.processInfo.arguments.contains("-startTour") {
                tour.start(fromBeginning: true)
            } else if !didOfferTour {
                didOfferTour = true
                // Let the workspace and its anchors finish their first layout
                // before the spotlight appears.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                tour.start(fromBeginning: true)
            }
        }
    }
}
