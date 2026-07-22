//
//  NavigationDrawerView.swift
//  penpal
//
//  One floating navigation surface that drills from folders into notes.
//

import SwiftUI

struct NavigationDrawerView: View {
    @ObservedObject var store: NotesStore
    var onSelectNote: (UUID) -> Void
    var onNewNote: () -> Void
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Page = .folders

    private enum Page {
        case folders
        case notes
    }

    var body: some View {
        NavigationStack {
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
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 8, y: 8)
        .accessibilityAddTraits(.isModal)
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
