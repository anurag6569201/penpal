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
    var onOpenSmartView: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var renameTarget: NoteFolder?
    @State private var renameText = ""
    @State private var deleteTarget: NoteFolder?
    @State private var moveTarget: NoteFolder?
    @State private var editorMode: FolderEditorMode?
    @State private var searchText = ""
    @State private var sortOption: NotesStore.FolderSortOption = .defaultOrder
    @State private var isEditing = false

    private enum FolderEditorMode: Identifiable {
        case create(parent: NoteFolder?)
        case customize(folder: NoteFolder)
        var id: String {
            switch self {
            case .create(let p): return "create-\(p?.id.uuidString ?? "root")"
            case .customize(let f): return "edit-\(f.id.uuidString)"
            }
        }
    }

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
                    if store.pinnedNotesCount > 0 {
                        pinnedSmartRow
                    }
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
                            guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

                let tags = store.allTags()
                if !tags.isEmpty && searchText.isEmpty {
                    Section {
                        tagsGrid(tags)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 8, trailing: 14))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("TAGS")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(Pen.inkPrimary)
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
        .sheet(item: $editorMode) { mode in
            FolderAppearanceSheet(
                title: {
                    switch mode {
                    case .create(let parent):
                        return parent == nil ? "New Folder" : "New Subfolder"
                    case .customize:
                        return "Customize Folder"
                    }
                }(),
                subtitle: {
                    switch mode {
                    case .create(let parent):
                        if let parent { return "Inside \"\(parent.name)\"" }
                        return "Organize subjects, courses, or projects."
                    case .customize:
                        return "Pick an icon and ink color so this folder stands out."
                    }
                }(),
                initialName: {
                    switch mode {
                    case .create: return ""
                    case .customize(let f): return f.name
                    }
                }(),
                initialIcon: {
                    switch mode {
                    case .create: return "folder"
                    case .customize(let f): return f.resolvedIconName
                    }
                }(),
                initialColor: {
                    switch mode {
                    case .create: return "teal"
                    case .customize(let f): return f.colorName ?? "teal"
                    }
                }()
            ) { name, icon, color in
                switch mode {
                case .create(let parent):
                    let newFolder = store.createFolder(named: name,
                                                       parentID: parent?.id,
                                                       iconName: icon,
                                                       colorName: color)
                    store.selectFolder(newFolder.id)
                    onSelectFolder(newFolder.id)
                case .customize(let folder):
                    store.renameFolder(folder.id, to: name)
                    store.updateFolderAppearance(folder.id, iconName: icon, colorName: color)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Pen.paper)
        }
        .sheet(item: $moveTarget) { folder in
            moveFolderSheet(for: folder)
                .presentationDetents([.medium, .large])
                .presentationBackground(Pen.paper)
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
                                let next = !isEditing
                                if next {
                                    // Keep the list aligned 1:1 with rootCustomFolders() while reordering.
                                    store.setAllCustomFoldersExpanded(false)
                                    searchText = ""
                                }
                                isEditing = next
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

    // MARK: - Smart Views & Tags

    private var pinnedSmartRow: some View {
        let isSelected = store.showPinnedOnly
        return HStack(spacing: 12) {
            Image(systemName: "pin.fill")
                .foregroundStyle(accent)
                .font(.body)
                .frame(width: 22)
            Text("Pinned")
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(Pen.inkPrimary)
            Spacer()
            Text("\(store.pinnedNotesCount)")
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
            Pen.tapHaptic()
            store.selectPinnedSmartView()
            onOpenSmartView?()
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

    private func tagsGrid(_ tags: [(tag: String, count: Int)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.tag) { item in
                let isSelected = store.selectedTagFilter?.caseInsensitiveCompare(item.tag) == .orderedSame
                Button {
                    Pen.tapHaptic()
                    store.selectTagSmartView(item.tag)
                    onOpenSmartView?()
                } label: {
                    HStack(spacing: 4) {
                        Text("#\(item.tag)")
                            .lineLimit(1)
                        Text("\(item.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? Pen.onAccent.opacity(0.85) : Pen.inkFaded)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Pen.onAccent : Pen.inkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? Pen.inkAccent : Pen.accentWash, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func moveFolderSheet(for folder: NoteFolder) -> some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.moveFolder(folder.id, toParentID: nil)
                        moveTarget = nil
                    } label: {
                        HStack {
                            Label("Top Level (No Parent)", systemImage: "tray")
                            Spacer()
                            if folder.parentID == nil {
                                Image(systemName: "checkmark").foregroundStyle(Pen.inkAccent)
                            }
                        }
                    }
                }

                let parents = store.validParentFolders(for: folder.id)
                if !parents.isEmpty {
                    Section("Nest Inside Folder") {
                        ForEach(parents, id: \.folder.id) { item in
                            Button {
                                store.moveFolder(folder.id, toParentID: item.folder.id)
                                moveTarget = nil
                            } label: {
                                HStack(spacing: 10) {
                                    if item.depth > 0 {
                                        Spacer().frame(width: CGFloat(item.depth * 14))
                                    }
                                    Image(systemName: item.folder.resolvedIconName)
                                        .foregroundStyle(item.folder.resolvedColor)
                                        .frame(width: 20)
                                    Text(item.folder.name)
                                        .foregroundStyle(Pen.inkPrimary)
                                    Spacer()
                                    if folder.parentID == item.folder.id {
                                        Image(systemName: "checkmark").foregroundStyle(Pen.inkAccent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Pen.paper.ignoresSafeArea())
            .tint(Pen.inkAccent)
            .navigationTitle("Move \"\(folder.name)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { moveTarget = nil }
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func systemRow(kind: NoteFolder.SystemFolderKind, icon: String, tint: Color) -> some View {
        if let folder = store.folders.first(where: { $0.systemKind == kind }) {
            let isSelected = store.selectedFolderID == folder.id
                && !store.showPinnedOnly
                && store.selectedTagFilter == nil
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

            Image(systemName: folder.resolvedIconName)
                .foregroundStyle(folder.resolvedColor)
                .font(.body)
                .frame(width: 22)

            Text(folder.name)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(Pen.inkPrimary)
                .lineLimit(1)

            Spacer()

            Text("\(store.recursiveNoteCount(for: folder))")
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
                editorMode = .customize(folder: folder)
            } label: {
                Label("Customize Icon & Color", systemImage: "paintpalette")
            }

            Button {
                renameTarget = folder
                renameText = folder.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                moveTarget = folder
            } label: {
                Label("Move Folder…", systemImage: "arrow.right.doc.on.clipboard")
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
        editorMode = .create(parent: parent)
    }
}

// MARK: - Folder Creator / Customizer Sheet

struct FolderAppearanceSheet: View {
    let title: String
    let subtitle: String
    @State private var name: String
    @State private var selectedIcon: String
    @State private var selectedColor: String
    let onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(title: String,
         subtitle: String,
         initialName: String,
         initialIcon: String,
         initialColor: String,
         onSave: @escaping (String, String, String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        _name = State(initialValue: initialName)
        _selectedIcon = State(initialValue: initialIcon)
        _selectedColor = State(initialValue: initialColor)
        self.onSave = onSave
    }

    private var activeColor: Color {
        NoteFolder.paletteColors.first(where: { $0.key == selectedColor })?.color ?? Pen.inkAccent
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: selectedIcon)
                            .font(.title2.weight(.medium))
                            .foregroundStyle(activeColor)
                            .frame(width: 48, height: 48)
                            .background(activeColor.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Folder name (e.g. Calculus)", text: $name)
                                .font(.headline)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Pen.inkFaded)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Pen.paperRaised)
                }

                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: 10)], spacing: 10) {
                        ForEach(NoteFolder.paletteColors, id: \.key) { item in
                            Button {
                                selectedColor = item.key
                            } label: {
                                Circle()
                                    .fill(item.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if selectedColor == item.key {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(selectedColor == item.key ? item.color : .clear, lineWidth: 2)
                                            .padding(-4)
                                    }
                                    .frame(width: 42, height: 42)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.label)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Pen.paperRaised)
                }

                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                        ForEach(NoteFolder.paletteIcons, id: \.symbol) { item in
                            let chosen = selectedIcon == item.symbol
                            Button {
                                selectedIcon = item.symbol
                            } label: {
                                Image(systemName: item.symbol)
                                    .font(.title3)
                                    .foregroundStyle(chosen ? Pen.onAccent : activeColor)
                                    .frame(width: 46, height: 46)
                                    .background(chosen ? activeColor : activeColor.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.label)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Pen.paperRaised)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Pen.paper.ignoresSafeArea())
            .tint(Pen.inkAccent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSave(trimmed, selectedIcon, selectedColor)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
