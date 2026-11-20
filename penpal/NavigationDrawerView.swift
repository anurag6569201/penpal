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
    @State private var dragOffset: CGFloat = 0

    private enum Page {
        case folders
        case notes
    }

    private var activeListTitle: String {
        if store.showPinnedOnly { return "Pinned" }
        if let tag = store.selectedTagFilter, !tag.isEmpty,
           store.selectedFolder?.systemKind == .allNotes {
            return "#\(tag)"
        }
        return store.selectedFolder?.name ?? "Notes"
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
                    onSelectFolder: { _ in showNotes() },
                    onOpenSmartView: { showNotes() },
                    onClose: onClose
                )
                .transition(pageTransition)

            case .notes:
                NotesListView(
                    store: store,
                    folderTitle: activeListTitle,
                    onBack: showFolders,
                    onClose: onClose,
                    onSelectNote: onSelectNote,
                    onNewNote: onNewNote
                )
                .transition(pageTransition)
            }
        }
        // Solid paper, not a translucent material — a blur over true AMOLED
        // black in dark mode still shows as a lighter grey haze, which broke
        // the "actually black" look the sidebar is meant to have.
        .background(Pen.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Pen.inkPrimary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 8, y: 8)
        .offset(x: min(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onChanged { value in
                    // Only track clear horizontal left-swipes to avoid fighting vertical list scroll.
                    guard value.translation.width < 0,
                          abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if value.translation.width < -90 || value.predictedEndTranslation.width < -150 {
                        dragOffset = 0
                        onClose()
                    } else {
                        withAnimation(reduceMotion ? nil : Pen.spring) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
        .onChange(of: isPresented) { _, open in
            // Every time it opens, land on the notes list (no slide animation).
            if open {
                page = .notes
                dragOffset = 0
            }
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: page == .folders ? .leading : .trailing)
            .combined(with: .opacity)
    }

    private func showFolders() {
        withAnimation(reduceMotion ? nil : Pen.spring) {
            page = .folders
        }
    }

    private func showNotes() {
        withAnimation(reduceMotion ? nil : Pen.spring) {
            page = .notes
        }
    }
}
