//
//  NotesListView.swift
//  penpal
//
//  Apple Notes style list + gallery, multi-select, rename, trash management.
//

import SwiftUI

struct NotesListView: View {
    @ObservedObject var store: NotesStore
    var folderTitle: String
    var onNewNote: () -> Void

    @State private var viewMode: ViewMode = .list
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var renameTarget: Note?
    @State private var renameText = ""
    @State private var showMoveSheet = false
    @State private var confirmEmptyTrash = false
    @State private var confirmDeleteSelected = false

    enum ViewMode { case list, gallery }

    private let selectionYellow = Color(red: 0.99, green: 0.79, blue: 0.11)

    private var isTrash: Bool { store.recentlyDeletedSelected }

    var body: some View {
        Group {
            if store.visibleNotes().isEmpty {
                emptyState
            } else if viewMode == .list {
                listView
            } else {
                galleryView
            }
        }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .searchable(text: $store.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search")
        .overlay(alignment: .bottom) {
            if selecting { selectionBar } else { newNoteBar }
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
        .sheet(isPresented: $showMoveSheet) {
            moveSheet
        }
        .confirmationDialog("Delete all notes in Recently Deleted? This can't be undone.",
                            isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.emptyRecentlyDeleted() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(selectedIDs.count) note\(selectedIDs.count == 1 ? "" : "s")?",
                            isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteNotes(selectedIDs, permanently: isTrash)
                endSelecting()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { selectedIDs = [] }
                    else { selectedIDs = Set(store.visibleNotes().map(\.id)) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelecting() }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select Notes", systemImage: "checkmark.circle") {
                        selecting = true
                    }
                    .disabled(store.visibleNotes().isEmpty)

                    Button(viewMode == .list ? "View as Gallery" : "View as List",
                           systemImage: viewMode == .list ? "square.grid.2x2" : "list.bullet") {
                        withAnimation { viewMode = viewMode == .list ? .gallery : .list }
                    }

                    if isTrash {
                        Divider()
                        Button("Recover All", systemImage: "arrow.uturn.backward") {
                            store.recoverAllDeleted()
                        }
                        .disabled(store.visibleNotes().isEmpty)
                        Button("Delete All", systemImage: "trash", role: .destructive) {
                            confirmEmptyTrash = true
                        }
                        .disabled(store.visibleNotes().isEmpty)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var allSelected: Bool {
        !store.visibleNotes().isEmpty && selectedIDs.count == store.visibleNotes().count
    }

    private func endSelecting() {
        selecting = false
        selectedIDs = []
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    // MARK: List

    private var listView: some View {
        List {
            ForEach(groupedNotes, id: \.title) { group in
                Section {
                    ForEach(group.notes) { note in
                        listRow(note)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            Color.clear.frame(height: 64).listRowSeparator(.hidden)
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
                    .foregroundStyle(selectedIDs.contains(note.id) ? selectionYellow : .secondary)
            }
            rowContent(note)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(note.id) } else { store.selectNote(note.id) }
        }
        .contextMenu { rowMenu(note) }
        .swipeActions(edge: .trailing) { swipeButtons(note) }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSel ? selectionYellow : Color.clear)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        )
    }

    private func rowContent(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(dateLabel(note)).foregroundStyle(.secondary)
                    Text(note.preview).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
            if let thumb = note.thumbnail {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
    }

    // MARK: Gallery

    private var galleryView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(store.visibleNotes()) { note in
                    galleryCard(note)
                }
            }
            .padding(16)
            .padding(.bottom, 64)
        }
    }

    private func galleryCard(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(0.78, contentMode: .fit)
                    .overlay {
                        if let thumb = note.thumbnail {
                            Image(uiImage: thumb)
                                .resizable().scaledToFill()
                        } else {
                            Text(note.preview)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(store.selectedNoteID == note.id && !selecting
                                          ? selectionYellow : Color.primary.opacity(0.08),
                                          lineWidth: store.selectedNoteID == note.id && !selecting ? 3 : 1)
                    )

                if selecting {
                    Image(systemName: selectedIDs.contains(note.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selectedIDs.contains(note.id) ? selectionYellow : .white)
                        .background(Circle().fill(.black.opacity(0.25)))
                        .padding(8)
                }
            }
            Text(note.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(dateLabel(note))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(note.id) } else { store.selectNote(note.id) }
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
            Button("Move To…", systemImage: "folder") {
                selectedIDs = [note.id]
                showMoveSheet = true
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.deleteNote(note.id)
            }
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
                .tint(.blue)
        } else {
            Button(role: .destructive) {
                store.deleteNote(note.id)
            } label: { Label("Delete", systemImage: "trash") }
            Button {
                renameTarget = note
                renameText = note.title.isEmpty ? note.displayTitle : note.title
            } label: { Label("Rename", systemImage: "pencil") }
                .tint(.orange)
        }
    }

    // MARK: Bottom bars

    private var newNoteBar: some View {
        HStack {
            Spacer()
            Text("\(store.visibleNotes().count) Notes")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .overlay(alignment: .trailing) {
            if !isTrash {
                Button(action: onNewNote) {
                    Image(systemName: "square.and.pencil")
                        .font(.title2).foregroundStyle(selectionYellow)
                }
                .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionBar: some View {
        HStack {
            if isTrash {
                Button("Recover") {
                    store.restoreNotes(selectedIDs)
                    endSelecting()
                }
                .disabled(selectedIDs.isEmpty)
            } else {
                Button("Move") { showMoveSheet = true }
                    .disabled(selectedIDs.isEmpty)
            }
            Spacer()
            Text(selectedIDs.isEmpty ? "Select Notes" : "\(selectedIDs.count) Selected")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button(isTrash ? "Delete" : "Delete", role: .destructive) {
                confirmDeleteSelected = true
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Move sheet

    private var moveSheet: some View {
        NavigationStack {
            List {
                ForEach(store.movableFolders()) { folder in
                    Button {
                        store.moveNotes(selectedIDs, to: folder.id)
                        showMoveSheet = false
                        endSelecting()
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
            }
            .navigationTitle("Move \(selectedIDs.count) Note\(selectedIDs.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoveSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isTrash ? "trash" : "note.text")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(isTrash ? "No Deleted Notes" : "No Notes")
                .font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            if !isTrash {
                Button("Create Note", action: onNewNote).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Grouping

    private struct NoteGroup { let title: String; let notes: [Note] }

    private var groupedNotes: [NoteGroup] {
        let cal = Calendar.current
        let notes = store.visibleNotes()
        var today: [Note] = []
        var yesterday: [Note] = []
        var previous7: [Note] = []
        var monthBuckets: [(String, [Note])] = []
        var yearBuckets: [(String, [Note])] = []

        let monthFormatter = DateFormatter(); monthFormatter.dateFormat = "MMMM"
        let yearFormatter = DateFormatter(); yearFormatter.dateFormat = "yyyy"

        // Group by creation date so sections always match the (stable,
        // created-newest-first) list order — editing a note no longer moves it.
        for note in notes {
            if cal.isDateInToday(note.createdAt) { today.append(note) }
            else if cal.isDateInYesterday(note.createdAt) { yesterday.append(note) }
            else if let days = cal.dateComponents([.day], from: note.createdAt, to: .now).day, days < 7 {
                previous7.append(note)
            } else if cal.isDate(note.createdAt, equalTo: .now, toGranularity: .year) {
                let key = monthFormatter.string(from: note.createdAt)
                if let idx = monthBuckets.firstIndex(where: { $0.0 == key }) { monthBuckets[idx].1.append(note) }
                else { monthBuckets.append((key, [note])) }
            } else {
                let key = yearFormatter.string(from: note.createdAt)
                if let idx = yearBuckets.firstIndex(where: { $0.0 == key }) { yearBuckets[idx].1.append(note) }
                else { yearBuckets.append((key, [note])) }
            }
        }

        var groups: [NoteGroup] = []
        if !today.isEmpty { groups.append(.init(title: "Today", notes: today)) }
        if !yesterday.isEmpty { groups.append(.init(title: "Yesterday", notes: yesterday)) }
        if !previous7.isEmpty { groups.append(.init(title: "Previous 7 Days", notes: previous7)) }
        for (t, items) in monthBuckets { groups.append(.init(title: t, notes: items)) }
        for (t, items) in yearBuckets { groups.append(.init(title: t, notes: items)) }
        return groups
    }

    private func dateLabel(_ note: Note) -> String {
        // Matches the createdAt-based grouping/ordering of the list.
        let cal = Calendar.current
        if cal.isDateInToday(note.createdAt) {
            return note.createdAt.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(note.createdAt) { return "Yesterday" }
        return note.createdAt.formatted(date: .numeric, time: .omitted)
    }
}
