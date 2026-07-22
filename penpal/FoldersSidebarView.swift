//
//  FoldersSidebarView.swift
//  penpal
//
//  Folder browser used by the floating navigation drawer.
//

import SwiftUI

struct FoldersSidebarView: View {
    @ObservedObject var store: NotesStore
    var onSelectFolder: (UUID) -> Void

    @State private var renameTarget: NoteFolder?
    @State private var renameText = ""

    // Warm Paper: the sidebar wears the same accent as the rest of the app.
    private let accent = Pen.inkAccent

    private var selection: Binding<UUID?> {
        Binding(
            get: { store.selectedFolderID },
            set: {
                if let id = $0 {
                    store.selectFolder(id)
                    onSelectFolder(id)
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                row(kind: .allNotes, icon: "tray.full", tint: accent)
                row(kind: .notes, icon: "folder", tint: accent)

                ForEach(store.rootCustomFolders()) { folder in
                    folderNode(folder)
                }
            }

            Section {
                row(kind: .recentlyDeleted, icon: "trash", tint: accent)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .tint(accent)
        .navigationTitle("Folders")
        .navigationBarTitleDisplayMode(.large)
        .alert("Rename Folder", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let id = renameTarget?.id {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.renameFolder(id, to: name) }
                }
                renameTarget = nil
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(kind: NoteFolder.SystemFolderKind, icon: String, tint: Color) -> some View {
        if let folder = store.folders.first(where: { $0.systemKind == kind }) {
            Label {
                Text(folder.name)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .badge(store.noteCount(for: folder))
            .tag(folder.id)
        }
    }

    private func folderNode(_ folder: NoteFolder) -> AnyView {
        let children = store.childFolders(of: folder.id)
        let label = folderLabel(folder)

        if children.isEmpty {
            return AnyView(label)
        }

        return AnyView(
            DisclosureGroup(isExpanded: expanded(folder)) {
                ForEach(children) { child in
                    folderNode(child)
                }
            } label: {
                label
            }
        )
    }

    private func folderLabel(_ folder: NoteFolder) -> some View {
        Label {
            Text(folder.name)
        } icon: {
            Image(systemName: "folder").foregroundStyle(accent)
        }
        .badge(store.noteCount(for: folder))
        .tag(folder.id)
        .contextMenu {
            Button {
                renameTarget = folder
                renameText = folder.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteFolder(folder.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.deleteFolder(folder.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameTarget = folder
                renameText = folder.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func expanded(_ folder: NoteFolder) -> Binding<Bool> {
        Binding(
            get: { folder.isExpanded },
            set: { _ in store.toggleExpanded(folder.id) }
        )
    }

}
