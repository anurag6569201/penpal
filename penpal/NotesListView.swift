//
//  NotesListView.swift
//  penpal
//
//  Ink Studio library: search, notes, gallery, and collection management.
//

import SwiftUI
import UIKit

private struct NoteThumbnailView<Placeholder: View>: View {
    let note: Note
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    private var cacheKey: String {
        let theme = colorScheme == .dark ? "dark" : "light"
        return "\(note.id.uuidString)-\(note.modifiedAt.timeIntervalSinceReferenceDate)-\(note.drawingData.count)-\(theme)"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: cacheKey) {
            guard !note.drawingData.isEmpty else {
                image = nil
                return
            }
            let data = note.drawingData
            let key = cacheKey
            let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
            let rendered = await Task.detached(priority: .utility) {
                Note.makeThumbnail(drawingData: data, cacheKey: key, userInterfaceStyle: style)
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

struct NotesListView: View {
    @ObservedObject var store: NotesStore
    var folderTitle: String
    var onBack: () -> Void
    var onClose: () -> Void
    var onSelectNote: (UUID) -> Void
    var onNewNote: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewMode: ViewMode = .list
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var renameTarget: Note?
    @State private var renameText = ""
    @State private var showMoveSheet = false
    @State private var confirmEmptyTrash = false
    @State private var confirmDeleteSelected = false
    @State private var tagTarget: Note?
    @State private var tagText = ""
    @State private var showBatchTagAlert = false
    @State private var batchTagText = ""
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var showCreateFolderInMove = false
    @State private var newFolderNameInMove = ""
    @State private var renameCurrentFolder = false
    @State private var currentFolderNameText = ""
    @State private var customizeCurrentFolder: NoteFolder?
    @State private var confirmDeleteCurrentFolder = false
    /// Soft-deleted note IDs offered for one-tap Undo.
    @State private var undoDeleteBanner: (id: UUID, noteIDs: Set<UUID>, message: String)?

    enum ViewMode { case list, gallery }

    private let selectionAccent = Pen.inkAccent

    private var isTrash: Bool { store.recentlyDeletedSelected }

    private var showsFolderBadgeOnRows: Bool {
        store.selectedFolder?.systemKind == .allNotes
            || store.showPinnedOnly
            || (store.searchAllFolders && !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        let visibleNotes = store.visibleNotes()
        let folderTags = store.tagsInCurrentFolder()
        let isSearching = !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFilterBar = !isTrash && !selecting && (
            !folderTags.isEmpty
            || store.pinnedNotesCount > 0
            || store.selectedTagFilter != nil
            || store.showPinnedOnly
            || (isSearching && store.selectedFolder?.systemKind != .allNotes)
        )
        VStack(spacing: 0) {
            listTopBar(visibleNotes: visibleNotes)
            if !selecting && (!visibleNotes.isEmpty || isSearching || store.selectedTagFilter != nil || store.showPinnedOnly) {
                sidebarHeader(hasVisibleNotes: !visibleNotes.isEmpty)
            }
            if hasFilterBar {
                filterStrip(tags: folderTags, isSearching: isSearching)
            }
            if isTrash && !visibleNotes.isEmpty && !selecting {
                trashBanner
            }
            Group {
                if visibleNotes.isEmpty {
                    emptyState
                } else if viewMode == .list {
                    listView(notes: visibleNotes)
                } else {
                    galleryView(notes: visibleNotes)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            if let banner = undoDeleteBanner {
                HStack(spacing: 12) {
                    Text(banner.message)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Pen.inkPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Undo") {
                        Pen.tapHaptic()
                        store.restoreNotes(banner.noteIDs)
                        withAnimation(reduceMotion ? nil : Pen.spring) {
                            undoDeleteBanner = nil
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Pen.inkAccent)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Pen.paperRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(Pen.inkAccent.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Pen.spring, value: undoDeleteBanner?.id)
        // The enclosing NavigationDrawerView already supplies a solid
        // Pen.paperRaised backing — a translucent material here would stack
        // into a greyer blur over true black in dark mode.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar } else { newNoteBar(noteCount: visibleNotes.count) }
        }
        .onAppear {
            if searchText != store.searchQuery {
                searchText = store.searchQuery
            }
        }
        .onChange(of: store.selectedFolderID) { _, _ in
            selecting = false
            selectedIDs = []
        }
        .alert("Rename Note", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let id = renameTarget?.id {
                    store.renameNote(id, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renameTarget = nil
            }
        }
        .alert("Tags", isPresented: Binding(
            get: { tagTarget != nil },
            set: { if !$0 { tagTarget = nil } }
        )) {
            TextField("Course, exam, revision", text: $tagText)
            Button("Cancel", role: .cancel) { tagTarget = nil }
            Button("Save") {
                if let id = tagTarget?.id {
                    store.updateTags(tagText.split(separator: ",").map(String.init), for: id)
                }
                tagTarget = nil
            }
        } message: {
            Text("Separate tags with commas. Tags make notes easy to find without moving them out of their folders.")
        }
        .alert("Add Tags to \(selectedIDs.count) Note\(selectedIDs.count == 1 ? "" : "s")",
               isPresented: $showBatchTagAlert) {
            TextField("e.g. Calculus, Exam", text: $batchTagText)
            Button("Cancel", role: .cancel) { batchTagText = "" }
            Button("Add") {
                let parsed = batchTagText.split(separator: ",").map(String.init)
                store.addTags(parsed, to: selectedIDs)
                batchTagText = ""
                endSelecting()
            }
        } message: {
            Text("Separate tags with commas.")
        }
        .sheet(isPresented: $showMoveSheet) {
            moveSheet
                .presentationBackground(Pen.paper)
        }
        .sheet(item: $customizeCurrentFolder) { folder in
            FolderAppearanceSheet(
                title: "Customize Folder",
                subtitle: "Pick an icon and ink color so this folder stands out.",
                initialName: folder.name,
                initialIcon: folder.resolvedIconName,
                initialColor: folder.colorName ?? "teal"
            ) { name, icon, color in
                store.renameFolder(folder.id, to: name)
                store.updateFolderAppearance(folder.id, iconName: icon, colorName: color)
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Pen.paper)
        }
        .confirmationDialog("Delete all notes in Recently Deleted? This can't be undone.",
                            isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.emptyRecentlyDeleted() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(selectedIDs.count) note\(selectedIDs.count == 1 ? "" : "s")?",
                            isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button(isTrash ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                let ids = selectedIDs
                store.deleteNotes(ids, permanently: isTrash)
                if !isTrash {
                    offerUndoDelete(for: ids)
                }
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: $renameCurrentFolder) {
            TextField("Folder Name", text: $currentFolderNameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let id = store.selectedFolderID {
                    let name = currentFolderNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.renameFolder(id, to: name) }
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(store.selectedFolder?.name ?? "Folder")\"?",
            isPresented: $confirmDeleteCurrentFolder,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let id = store.selectedFolderID {
                    store.deleteFolder(id)
                    onBack()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes inside will be moved to the Notes folder so you don't lose any thoughts.")
        }
    }

    // MARK: Top bar (in-body, so it stays within the sidebar)

    private func listTopBar(visibleNotes: [Note]) -> some View {
        let allSelected = !visibleNotes.isEmpty && selectedIDs.count == visibleNotes.count
        return HStack(spacing: 12) {
            if selecting {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { selectedIDs = [] }
                    else { selectedIDs = Set(visibleNotes.map(\.id)) }
                }
                Spacer(minLength: 0)
                Text("\(selectedIDs.count) Selected")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Done") { endSelecting() }
                    .fontWeight(.semibold)
            } else {
                Button(action: onBack) {
                    Label("Folders", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .frame(minHeight: 40)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Text(folderTitle)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(Pen.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Pen.inkFaded)
                        .frame(width: 32, height: 32)
                        .background(Pen.inkPrimary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close library")
            }
        }
        .tint(Pen.inkAccent)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: In-sidebar header (search + actions)

    /// Search and the Select / Gallery actions live INSIDE the sidebar body, not
    /// in the navigation bar. In the floating drawer, `.searchable` and nav-bar
    /// toolbar items were surfacing in the app's top bar to the right of the
    /// panel; keeping them in the body guarantees they stay within the sidebar.
    private func sidebarHeader(hasVisibleNotes: Bool) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Pen.inkFaded)
                TextField("Search notes, ink, #tags", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, value in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            guard !Task.isCancelled else { return }
                            store.searchQuery = value
                        }
                    }
                    .onChange(of: store.searchQuery) { _, value in
                        if searchText != value { searchText = value }
                    }
                if !store.searchQuery.isEmpty || !searchText.isEmpty {
                    Button {
                        searchTask?.cancel()
                        searchText = ""
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Pen.inkFaded)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(Pen.inkPrimary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                Pen.tapHaptic()
                withAnimation(reduceMotion ? nil : Pen.spring) {
                    viewMode = viewMode == .list ? .gallery : .list
                }
            } label: {
                Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Pen.inkPrimary)
                    .frame(width: 38, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewMode == .list ? "View as Gallery" : "View as List")

            Menu {
                Menu("Sort By", systemImage: "arrow.up.arrow.down") {
                    ForEach(NotesStore.NoteSortOption.allCases) { option in
                        Button {
                            store.noteSortOption = option
                        } label: {
                            Label(option.rawValue,
                                  systemImage: store.noteSortOption == option ? "checkmark" : "")
                        }
                    }
                }

                Button("Select Notes", systemImage: "checkmark.circle") {
                    selecting = true
                }
                .disabled(!hasVisibleNotes)

                if isTrash {
                    Divider()
                    Button("Recover All", systemImage: "arrow.uturn.backward") {
                        store.recoverAllDeleted()
                    }
                    .disabled(!hasVisibleNotes)
                    Button("Delete All", systemImage: "trash", role: .destructive) {
                        confirmEmptyTrash = true
                    }
                    .disabled(!hasVisibleNotes)
                }

                if let customFolder = store.selectedFolder, customFolder.systemKind == nil {
                    Divider()
                    Button("Customize Icon & Color", systemImage: "paintpalette") {
                        customizeCurrentFolder = customFolder
                    }
                    Button("Rename Folder", systemImage: "pencil") {
                        currentFolderNameText = customFolder.name
                        renameCurrentFolder = true
                    }
                    Button("Delete Folder", systemImage: "trash", role: .destructive) {
                        confirmDeleteCurrentFolder = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Pen.inkPrimary)
                    .frame(width: 38, height: 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func filterStrip(tags: [(tag: String, count: Int)], isSearching: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if isSearching && store.selectedFolder?.systemKind != .allNotes {
                    filterChip(
                        title: store.searchAllFolders ? "All Folders" : "This Folder",
                        icon: store.searchAllFolders ? "tray.full" : "folder",
                        active: store.searchAllFolders
                    ) {
                        store.searchAllFolders.toggle()
                    }
                }

                filterChip(
                    title: "All",
                    icon: nil,
                    active: !store.showPinnedOnly && store.selectedTagFilter == nil
                ) {
                    store.showPinnedOnly = false
                    store.selectedTagFilter = nil
                }

                if store.pinnedNotesCount > 0 || store.showPinnedOnly {
                    filterChip(
                        title: "Pinned",
                        icon: "pin.fill",
                        active: store.showPinnedOnly
                    ) {
                        store.showPinnedOnly.toggle()
                    }
                }

                ForEach(tags, id: \.tag) { item in
                    let isSelected = store.selectedTagFilter?.caseInsensitiveCompare(item.tag) == .orderedSame
                    filterChip(
                        title: "#\(item.tag)",
                        icon: nil,
                        active: isSelected
                    ) {
                        store.selectedTagFilter = isSelected ? nil : item.tag
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    private func filterChip(title: String, icon: String?, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Pen.tapHaptic()
            action()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(active ? Pen.onAccent : Pen.inkPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? Pen.inkAccent : Pen.inkPrimary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var trashBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(Pen.inkAccent)
            Text("Swipe right on any note to recover it.")
                .font(.caption)
                .foregroundStyle(Pen.inkFaded)
            Spacer()
            Button("Empty") { confirmEmptyTrash = true }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Pen.inkPrimary.opacity(0.04))
    }

    private func offerUndoDelete(for ids: Set<UUID>) {
        let count = ids.count
        let message = count == 1 ? "Moved to Recently Deleted" : "Moved \(count) notes to Trash"
        let bannerID = UUID()
        withAnimation(reduceMotion ? nil : Pen.spring) {
            undoDeleteBanner = (bannerID, ids, message)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            guard undoDeleteBanner?.id == bannerID else { return }
            withAnimation(reduceMotion ? nil : Pen.spring) {
                undoDeleteBanner = nil
            }
        }
    }

    private func endSelecting() {
        selecting = false
        selectedIDs = []
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    // MARK: List

    private func listView(notes: [Note]) -> some View {
        List {
            ForEach(groupedNotes(from: notes), id: \.title) { group in
                Section {
                    ForEach(group.notes) { note in
                        listRow(note)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(Pen.inkPrimary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 10)
    }

    private func listRow(_ note: Note) -> some View {
        let isSel = store.selectedNoteID == note.id && !selecting
        return HStack(spacing: 10) {
            if selecting {
                Image(systemName: selectedIDs.contains(note.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIDs.contains(note.id) ? selectionAccent : Pen.inkFaded)
            }
            rowContent(note)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(note.id) } else { onSelectNote(note.id) }
        }
        .contextMenu { rowMenu(note) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipeButtons(note) }
        .swipeActions(edge: .trailing) { swipeButtons(note) }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSel ? Pen.accentWash : Color.clear)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        )
    }

    private func rowContent(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(note.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Pen.inkPrimary)
                        .lineLimit(1)
                    if note.isCoded {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Pen.inkAccent)
                    }
                }
                HStack(spacing: 6) {
                    Text(dateLabel(note)).foregroundStyle(Pen.inkFaded)
                    Text(note.preview).foregroundStyle(Pen.inkFaded).lineLimit(1)
                }
                .font(.subheadline)
                if showsFolderBadgeOnRows || !note.normalizedTags.isEmpty {
                    HStack(spacing: 6) {
                        if showsFolderBadgeOnRows, let folder = store.folder(for: note.folderID) {
                            HStack(spacing: 3) {
                                Image(systemName: folder.resolvedIconName)
                                    .font(.caption2)
                                Text(folder.name)
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(folder.resolvedColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(folder.resolvedColor.opacity(0.12), in: Capsule())
                        }
                        if !note.normalizedTags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(note.normalizedTags.prefix(3), id: \.self) { tag in
                                    Button {
                                        Pen.tapHaptic()
                                        store.selectedTagFilter = tag
                                    } label: {
                                        Text("#\(tag)")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(Pen.inkAccent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if note.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Pen.inkAccent)
                    .accessibilityLabel("Pinned")
            }
            if !note.drawingData.isEmpty {
                NoteThumbnailView(note: note) { EmptyView() }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Pen.inkPrimary.opacity(0.08), lineWidth: 0.5))
            }
        }
    }

    // MARK: Gallery

    private func galleryView(notes: [Note]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(notes) { note in
                    galleryCard(note)
                }
            }
            .padding(16)
            .padding(.bottom, 12)
        }
    }

    private func galleryCard(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Pen.paperRaised)
                    .aspectRatio(0.78, contentMode: .fit)
                    .overlay {
                        if !note.drawingData.isEmpty {
                            NoteThumbnailView(note: note) {
                                Text(note.preview)
                                    .font(.caption2)
                                    .foregroundStyle(Pen.inkFaded)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        } else {
                            Text(note.preview)
                                .font(.caption2)
                                .foregroundStyle(Pen.inkFaded)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(store.selectedNoteID == note.id && !selecting
                                          ? selectionAccent : Pen.inkPrimary.opacity(0.08),
                                          lineWidth: store.selectedNoteID == note.id && !selecting ? 3 : 1)
                    )

                if selecting {
                    Image(systemName: selectedIDs.contains(note.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selectedIDs.contains(note.id) ? selectionAccent : .white)
                        .background(Circle().fill(.black.opacity(0.25)))
                        .padding(8)
                }
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Pen.inkAccent)
                        .padding(8)
                }
            }
            Text(note.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(dateLabel(note))
                .font(.caption)
                .foregroundStyle(Pen.inkFaded)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(note.id) } else { onSelectNote(note.id) }
        }
        .contextMenu { rowMenu(note) }
    }

    // MARK: Row actions

    @ViewBuilder
    private func rowMenu(_ note: Note) -> some View {
        if note.isDeleted {
            Button("Recover", systemImage: "arrow.uturn.backward") { store.restoreNote(note.id) }
            Button("Delete Immediately", systemImage: "trash", role: .destructive) {
                store.deleteNote(note.id, permanently: true)
            }
        } else {
            Button("Rename", systemImage: "pencil") {
                renameTarget = note
                renameText = note.title.isEmpty ? note.displayTitle : note.title
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                Pen.tapHaptic()
                if let copy = store.duplicateNote(note.id) {
                    onSelectNote(copy.id)
                }
            }
            Button("Move To…", systemImage: "folder") {
                selectedIDs = [note.id]
                showMoveSheet = true
            }
            Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") {
                store.setPinned(!note.pinned, for: note.id)
            }
            Button("Edit Tags", systemImage: "tag") {
                tagTarget = note
                tagText = note.normalizedTags.joined(separator: ", ")
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.deleteNote(note.id)
                offerUndoDelete(for: [note.id])
            }
        }
    }

    @ViewBuilder
    private func leadingSwipeButtons(_ note: Note) -> some View {
        if note.isDeleted {
            Button {
                Pen.tapHaptic()
                store.restoreNote(note.id)
            } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                .tint(Pen.inkPositive)
        } else {
            Button {
                Pen.tapHaptic()
                store.setPinned(!note.pinned, for: note.id)
            } label: {
                Label(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin")
            }
            .tint(Pen.inkAccent)

            Button {
                selectedIDs = [note.id]
                showMoveSheet = true
            } label: {
                Label("Move", systemImage: "folder")
            }
            .tint(Pen.inkCaution)
        }
    }

    @ViewBuilder
    private func swipeButtons(_ note: Note) -> some View {
        if note.isDeleted {
            Button(role: .destructive) {
                store.deleteNote(note.id, permanently: true)
            } label: { Label("Delete", systemImage: "trash") }
            Button {
                store.restoreNote(note.id)
            } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                .tint(Pen.inkPositive)
        } else {
            Button(role: .destructive) {
                store.deleteNote(note.id)
                offerUndoDelete(for: [note.id])
            } label: { Label("Delete", systemImage: "trash") }
            Button {
                renameTarget = note
                renameText = note.title.isEmpty ? note.displayTitle : note.title
            } label: { Label("Rename", systemImage: "pencil") }
                .tint(Pen.inkAccent)
        }
    }

    // MARK: Bottom bars

    private func newNoteBar(noteCount: Int) -> some View {
        VStack(spacing: 10) {
            if !isTrash {
                Button {
                    Pen.tapHaptic()
                    onNewNote()
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .buttonStyle(PenPrimaryButtonStyle())
            }
            Text("\(noteCount) note\(noteCount == 1 ? "" : "s") in this view")
                .font(Pen.caption).foregroundStyle(Pen.inkFaded)
        }
        .padding(16)
        .background(Pen.paperRaised)
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            if isTrash {
                Button {
                    store.restoreNotes(selectedIDs)
                    endSelecting()
                } label: {
                    Label("Recover", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(selectedIDs.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    confirmDeleteSelected = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(selectedIDs.isEmpty)
            } else {
                Button { showMoveSheet = true } label: {
                    Image(systemName: "folder")
                        .frame(width: 36, height: 36)
                }
                .disabled(selectedIDs.isEmpty)
                .accessibilityLabel("Move selected notes")

                Button {
                    batchTagText = ""
                    showBatchTagAlert = true
                } label: {
                    Image(systemName: "tag")
                        .frame(width: 36, height: 36)
                }
                .disabled(selectedIDs.isEmpty)
                .accessibilityLabel("Add tags to selected notes")

                Button {
                    let anyUnpinned = store.notes.contains { selectedIDs.contains($0.id) && !$0.pinned }
                    store.setPinned(anyUnpinned, for: selectedIDs)
                    endSelecting()
                } label: {
                    Image(systemName: "pin")
                        .frame(width: 36, height: 36)
                }
                .disabled(selectedIDs.isEmpty)
                .accessibilityLabel("Pin or unpin selected notes")

                Button {
                    store.duplicateNotes(selectedIDs)
                    endSelecting()
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .frame(width: 36, height: 36)
                }
                .disabled(selectedIDs.isEmpty)
                .accessibilityLabel("Duplicate selected notes")

                Spacer()

                Button(role: .destructive) {
                    confirmDeleteSelected = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 36, height: 36)
                }
                .disabled(selectedIDs.isEmpty)
                .accessibilityLabel("Delete selected notes")
            }
        }
        .tint(Pen.inkAccent)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Pen.paperRaised)
    }

    // MARK: Move sheet

    private var moveSheet: some View {
        let currentFolderID: UUID? = selectedIDs.count == 1
            ? store.notes.first(where: { $0.id == selectedIDs.first })?.folderID
            : nil
        return NavigationStack {
            List {
                Section {
                    Button {
                        newFolderNameInMove = ""
                        showCreateFolderInMove = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Pen.inkAccent)
                    }
                }

                Section("Folders") {
                    ForEach(store.orderedMovableFolders(), id: \.folder.id) { item in
                        Button {
                            store.moveNotes(selectedIDs, to: item.folder.id)
                            showMoveSheet = false
                            endSelecting()
                        } label: {
                            HStack(spacing: 10) {
                                if item.depth > 0 {
                                    Spacer().frame(width: CGFloat(item.depth * 16))
                                }
                                Image(systemName: item.folder.resolvedIconName)
                                    .foregroundStyle(item.folder.resolvedColor)
                                    .frame(width: 22)
                                Text(item.folder.name)
                                    .foregroundStyle(Pen.inkPrimary)
                                Spacer()
                                Text("\(store.recursiveNoteCount(for: item.folder))")
                                    .font(.caption)
                                    .foregroundStyle(Pen.inkFaded)
                                if currentFolderID == item.folder.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Pen.inkAccent)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Pen.paper.ignoresSafeArea())
            .tint(Pen.inkAccent)
            .navigationTitle("Move \(selectedIDs.count) Note\(selectedIDs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Pen.paper, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoveSheet = false }
                }
            }
            .alert("New Folder", isPresented: $showCreateFolderInMove) {
                TextField("Folder Name", text: $newFolderNameInMove)
                Button("Cancel", role: .cancel) {}
                Button("Create & Move") {
                    let name = newFolderNameInMove.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        let newFolder = store.createFolder(named: name)
                        store.moveNotes(selectedIDs, to: newFolder.id)
                        showMoveSheet = false
                        endSelecting()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Empty state

    private var emptyState: some View {
        let searching = !store.searchQuery.isEmpty
        let filtered = store.showPinnedOnly || store.selectedTagFilter != nil
        return VStack(spacing: 16) {
            Image(systemName: searching ? "magnifyingglass" : (isTrash ? "trash" : (filtered ? "line.3.horizontal.decrease.circle" : "pencil.and.outline")))
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Pen.inkAccent)
                .frame(width: 80, height: 80)
                .background(Pen.accentWash, in: RoundedRectangle(cornerRadius: 24))
            Text(searching ? "No matching thoughts" : (isTrash ? "Nothing here for now" : (filtered ? "No notes match this filter" : "A little room to think")))
                .font(.system(.title2, design: .serif)).foregroundStyle(Pen.inkPrimary)
            Text(searching ? "Try a different keyword or search all folders." : (isTrash ? "Deleted notes will appear here." : (filtered ? "Clear the active filter to see everything in this folder." : "Start with a question, a sketch, or whatever is on your mind.")))
                .font(Pen.sub).foregroundStyle(Pen.inkFaded)
                .multilineTextAlignment(.center)
            if searching && !store.searchAllFolders && store.selectedFolder?.systemKind != .allNotes {
                Button("Search All Folders") {
                    store.searchAllFolders = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Pen.inkAccent)
            }
            if searching || filtered {
                Button("Clear filters") {
                    searchText = ""
                    store.searchQuery = ""
                    store.selectedTagFilter = nil
                    store.showPinnedOnly = false
                }
                .buttonStyle(PenQuietButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pen.paperRaised)
    }

    // MARK: Grouping

    private struct NoteGroup { let title: String; let notes: [Note] }

    private func groupingDate(for note: Note) -> Date {
        store.noteSortOption == .dateCreated ? note.createdAt : note.modifiedAt
    }

    private func groupedNotes(from notes: [Note]) -> [NoteGroup] {
        let pinned = notes.filter(\.pinned)
        let unpinned = notes.filter { !$0.pinned }

        if store.noteSortOption == .titleAsc {
            var groups: [NoteGroup] = []
            if !pinned.isEmpty { groups.append(.init(title: "Pinned", notes: pinned)) }
            if !unpinned.isEmpty { groups.append(.init(title: "A–Z", notes: unpinned)) }
            return groups
        }

        let cal = Calendar.current
        var today: [Note] = []
        var yesterday: [Note] = []
        var previous7: [Note] = []
        var monthBuckets: [(String, [Note])] = []
        var yearBuckets: [(String, [Note])] = []

        let monthFormatter = DateFormatter(); monthFormatter.dateFormat = "MMMM"
        let yearFormatter = DateFormatter(); yearFormatter.dateFormat = "yyyy"

        for note in unpinned {
            let d = groupingDate(for: note)
            if cal.isDateInToday(d) { today.append(note) }
            else if cal.isDateInYesterday(d) { yesterday.append(note) }
            else if let days = cal.dateComponents([.day], from: d, to: .now).day, days < 7 {
                previous7.append(note)
            } else if cal.isDate(d, equalTo: .now, toGranularity: .year) {
                let key = monthFormatter.string(from: d)
                if let idx = monthBuckets.firstIndex(where: { $0.0 == key }) { monthBuckets[idx].1.append(note) }
                else { monthBuckets.append((key, [note])) }
            } else {
                let key = yearFormatter.string(from: d)
                if let idx = yearBuckets.firstIndex(where: { $0.0 == key }) { yearBuckets[idx].1.append(note) }
                else { yearBuckets.append((key, [note])) }
            }
        }

        var groups: [NoteGroup] = []
        if !pinned.isEmpty { groups.append(.init(title: "Pinned", notes: pinned)) }
        if !today.isEmpty { groups.append(.init(title: "Today", notes: today)) }
        if !yesterday.isEmpty { groups.append(.init(title: "Yesterday", notes: yesterday)) }
        if !previous7.isEmpty { groups.append(.init(title: "Previous 7 Days", notes: previous7)) }
        for (t, items) in monthBuckets { groups.append(.init(title: t, notes: items)) }
        for (t, items) in yearBuckets { groups.append(.init(title: t, notes: items)) }
        return groups
    }

    private func dateLabel(_ note: Note) -> String {
        let d = groupingDate(for: note)
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .numeric, time: .omitted)
    }
}
