//
//  FoldersSidebarView.swift
//  penpal
//
//  Complete folder browser and library manager used by the navigation drawer.
//

import SwiftUI

struct FoldersSidebarView: View {
    @ObservedObject var store: NotesStore
    var onSelectFolder: (UUID) -> Void
    var onClose: (() -> Void)? = nil

    @State private var renameTarget: NoteFolder?
    @State private var renameText = ""
    @State private var deleteTarget: NoteFolder?
    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var parentFolderForNew: NoteFolder?
    @State private var searchText = ""
    @State private var sortOption: NotesStore.FolderSortOption = .defaultOrder
    @State private var isEditing = false

    private let accent = Pen.inkAccent

    private var filteredRootFolders: [NoteFolder] {
        let roots = store.rootCustomFolders()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return roots }
        return roots.filter { matchesFolderOrDescendant($0, query: query) }
    }

    private func matchesFolderOrDescendant(_ folder: NoteFolder, query: String) -> Bool {
        if folder.name.lowercased().contains(query) { return true }
        let children = store.childFolders(of: folder.id)
        return children.contains { matchesFolderOrDescendant($0, query: query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if store.customFoldersCount > 0 || !searchText.isEmpty {
                searchBar
            }

            List {
                Section {
                    systemRow(kind: .allNotes, icon: "tray.full", tint: accent)
                    systemRow(kind: .notes, icon: "folder", tint: accent)
                }

                Section {
                    if store.customFoldersCount == 0 && searchText.isEmpty {
                        emptyFoldersBanner
                    } else if filteredRootFolders.isEmpty && !searchText.isEmpty {
                        Text("No matching folders")
                            .font(Pen.caption)
                            .foregroundStyle(Pen.inkFaded)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredRootFolders) { folder in
                            folderNode(folder, depth: 0)
                        }
                        .onMove { indices, newOffset in
                            store.moveCustomFolders(fromOffsets: indices, toOffset: newOffset, parentID: nil)
                        }
                    }
                } header: {
                    HStack {
                        Text("FOLDERS")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(Pen.inkPrimary)
                        Spacer()
                        Button {
                            Pen.tapHaptic()
                            startCreatingFolder(parent: nil)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("New")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Pen.inkAccent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    systemRow(kind: .recentlyDeleted, icon: "trash", tint: accent)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 10)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        }
        .tint(accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .alert(parentFolderForNew == nil ? "New Folder" : "New Subfolder", isPresented: $showCreateFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                resetCreateState()
            }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let newFolder = store.createFolder(named: name, parentID: parentFolderForNew?.id)
                    store.selectFolder(newFolder.id)
                    onSelectFolder(newFolder.id)
                }
                resetCreateState()
            }
        } message: {
            if let parent = parentFolderForNew {
                Text("This will be created inside \"\(parent.name)\".")
            } else {
                Text("Create a folder to group your notes and sketches.")
            }
        }
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
        .confirmationDialog(
            "Delete \"\(deleteTarget?.name ?? "Folder")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let id = deleteTarget?.id {
                    store.deleteFolder(id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("Notes inside will be moved to the Notes folder so you don't lose any thoughts.")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Your library")
                .font(Pen.titleSerif)
                .foregroundStyle(Pen.inkPrimary)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    Pen.tapHaptic()
                    startCreatingFolder(parent: nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Pen.inkAccent)
                        .frame(width: 34, height: 34)
                        .background(Pen.accentWash, in: Circle())
                }
                .accessibilityLabel("Create folder")

                Menu {
                    Button {
                        startCreatingFolder(parent: nil)
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }

                    Divider()

                    Menu {
                        ForEach(NotesStore.FolderSortOption.allCases) { opt in
                            Button {
                                sortOption = opt
                                store.sortCustomFolders(by: opt)
                            } label: {
                                HStack {
                                    Text(opt.rawValue)
                                    if sortOption == opt {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sort Folders", systemImage: "arrow.up.arrow.down")
                    }

                    Button {
                        store.setAllCustomFoldersExpanded(true)
                    } label: {
                        Label("Expand All", systemImage: "chevron.down.circle")
                    }

                    Button {
                        store.setAllCustomFoldersExpanded(false)
                    } label: {
                        Label("Collapse All", systemImage: "chevron.right.circle")
                    }

                    if store.customFoldersCount > 1 {
                        Divider()
                        Button {
                            withAnimation(Pen.spring) {
                                isEditing.toggle()
                            }
                        } label: {
                            Label(isEditing ? "Done Reordering" : "Reorder Folders",
                                  systemImage: isEditing ? "checkmark" : "arrow.up.and.down")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Pen.inkPrimary)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Folder options")

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Pen.inkFaded)
                            .frame(width: 32, height: 32)
                            .background(Pen.inkPrimary.opacity(0.06), in: Circle())
                    }
                    .accessibilityLabel("Close library")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Pen.inkFaded)
                .font(.footnote)
            TextField("Search folders", text: $searchText)
                .textFieldStyle(.plain)
                .font(Pen.sub)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Pen.inkFaded)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Pen.inkPrimary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Rows

    @ViewBuilder
    private func systemRow(kind: NoteFolder.SystemFolderKind, icon: String, tint: Color) -> some View {
        if let folder = store.folders.first(where: { $0.systemKind == kind }) {
            let isSelected = store.selectedFolderID == folder.id
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.body)
                    .frame(width: 22)
                Text(folder.name)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(Pen.inkPrimary)
                Spacer()
                Text("\(store.noteCount(for: folder))")
                    .font(Pen.caption)
                    .foregroundStyle(isSelected ? Pen.inkPrimary : Pen.inkFaded)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(isSelected ? Pen.inkAccent.opacity(0.18) : Pen.inkPrimary.opacity(0.05),
                                in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectFolder(folder.id)
                onSelectFolder(folder.id)
            }
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Pen.accentWash : Color.clear)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            )
        }
    }

    // MARK: - Folder Tree

    private func folderNode(_ folder: NoteFolder, depth: Int = 0) -> AnyView {
        let children = store.childFolders(of: folder.id)
        let row = folderRow(folder, depth: depth, hasChildren: !children.isEmpty)

        if children.isEmpty || !folder.isExpanded {
            return AnyView(row)
        }

        return AnyView(
            Group {
                row
                ForEach(children) { child in
                    folderNode(child, depth: depth + 1)
                }
            }
        )
    }

    private func folderRow(_ folder: NoteFolder, depth: Int, hasChildren: Bool) -> some View {
        let isSelected = store.selectedFolderID == folder.id
        return HStack(spacing: 8) {
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(depth * 14))
            }

            if hasChildren {
                Button {
                    withAnimation(Pen.spring) {
                        store.toggleExpanded(folder.id)
                    }
                } label: {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Pen.inkFaded)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: 18)
            }

            Image(systemName: hasChildren && folder.isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(accent)
                .font(.body)
                .frame(width: 22)

            Text(folder.name)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(Pen.inkPrimary)
                .lineLimit(1)

            Spacer()

            Text("\(store.noteCount(for: folder))")
                .font(Pen.caption)
                .foregroundStyle(isSelected ? Pen.inkPrimary : Pen.inkFaded)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(isSelected ? Pen.inkAccent.opacity(0.18) : Pen.inkPrimary.opacity(0.05),
                            in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectFolder(folder.id)
            onSelectFolder(folder.id)
        }
        .contextMenu {
            Button {
                startCreatingFolder(parent: folder)
            } label: {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }

            Button {
                renameTarget = folder
                renameText = folder.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                store.duplicateFolder(folder.id)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Divider()

            Button(role: .destructive) {
                deleteTarget = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                renameTarget = folder
                renameText = folder.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Pen.inkAccent)
        }
        .swipeActions(edge: .leading) {
            Button {
                startCreatingFolder(parent: folder)
            } label: {
                Label("Add Subfolder", systemImage: "folder.badge.plus")
            }
            .tint(Pen.inkAccent)
        }
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Pen.accentWash : Color.clear)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
        )
    }

    // MARK: - Empty State

    private var emptyFoldersBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
                .background(Pen.accentWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(spacing: 4) {
                Text("No folders yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Pen.inkPrimary)
                Text("Create folders to organize classes, projects, or thoughts.")
                    .font(Pen.caption)
                    .foregroundStyle(Pen.inkFaded)
                    .multilineTextAlignment(.center)
            }

            Button {
                Pen.tapHaptic()
                startCreatingFolder(parent: nil)
            } label: {
                Label("Create folder", systemImage: "plus")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Pen.inkAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Pen.accentWash, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(Pen.inkPrimary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5)
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .listRowSeparator(.hidden)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                Pen.tapHaptic()
                startCreatingFolder(parent: nil)
            } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(PenPrimaryButtonStyle())

            Text("\(store.customFoldersCount) folder\(store.customFoldersCount == 1 ? "" : "s") · \(store.totalActiveNotesCount) notes in library")
                .font(Pen.caption)
                .foregroundStyle(Pen.inkFaded)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Pen.paperRaised)
    }

    // MARK: - Helpers

    private func startCreatingFolder(parent: NoteFolder?) {
        parentFolderForNew = parent
        newFolderName = ""
        showCreateFolder = true
    }

    private func resetCreateState() {
        showCreateFolder = false
        parentFolderForNew = nil
        newFolderName = ""
    }
}
