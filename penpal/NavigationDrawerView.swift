//
//  NavigationDrawerView.swift
//  penpal
//
//  One floating navigation surface that drills from folders into notes.
//

import SwiftUI

struct NavigationDrawerView: View {
    @ObservedObject var store: NotesStore
    /// Whether the drawer is currently shown, so it can reset to the notes list
    /// each time it opens.
    var isPresented: Bool
    var onSelectNote: (UUID) -> Void
    var onNewNote: () -> Void
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Default to the notes list — the drawer opens where the note lives; the
    /// user can step out to folders from there.
    @State private var page: Page = .notes

    private enum Page {
        case folders
        case notes
    }

    var body: some View {
        // Deliberately NOT a NavigationStack: the drawer renders its own headers
        // in-body. A nested navigation bar here merges with the app's root bar —
        // its buttons leaked into the editor tools, and hiding it hid the editor
        // toolbar too. Owning the chrome ourselves avoids both.
        Group {
            switch page {
            case .folders:
                FoldersSidebarView(
                    store: store,
                    onSelectFolder: { _ in showNotes() }
                )
                .transition(pageTransition)

            case .notes:
                NotesListView(
                    store: store,
                    folderTitle: store.selectedFolder?.name ?? "Notes",
                    onBack: showFolders,
                    onClose: onClose,
                    onSelectNote: onSelectNote,
                    onNewNote: onNewNote
                )
                .transition(pageTransition)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 8, y: 8)
        .accessibilityAddTraits(.isModal)
        .onChange(of: isPresented) { _, open in
            // Every time it opens, land on the notes list (no slide animation).
            if open { page = .notes }
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: page == .folders ? .leading : .trailing)
            .combined(with: .opacity)
    }

    private func showFolders() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            page = .folders
        }
    }

    private func showNotes() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            page = .notes
        }
    }
}
