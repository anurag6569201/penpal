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
    @State private var image: UIImage?

    private var cacheKey: String {
        "\(note.id.uuidString)-\(note.modifiedAt.timeIntervalSinceReferenceDate)-\(note.drawingData.count)"
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
            let rendered = await Task.detached(priority: .utility) {
                Note.makeThumbnail(drawingData: data, cacheKey: key)
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
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    enum ViewMode { case list, gallery }

    private let selectionAccent = Pen.inkAccent

    private var isTrash: Bool { store.recentlyDeletedSelected }

    var body: some View {
        let visibleNotes = store.visibleNotes()
        VStack(spacing: 0) {
            listTopBar(visibleNotes: visibleNotes)
            if !selecting && (!visibleNotes.isEmpty || !store.searchQuery.isEmpty) {
                sidebarHeader(hasVisibleNotes: !visibleNotes.isEmpty)
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
        // The enclosing NavigationDrawerView already supplies a solid
        // Pen.paperRaised backing — a translucent material here would stack
        // into a greyer blur over true black in dark mode.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar } else { newNoteBar(noteCount: visibleNotes.count) }
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
        .sheet(isPresented: $showMoveSheet) {
            moveSheet
                .presentationBackground(Pen.paper)
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
                        .frame(minHeight: 44)
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 16)
                Text(folderTitle)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(Pen.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                    .accessibilityAddTraits(.isHeader)
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
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Pen.inkFaded)
                TextField("Find a thought", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, value in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard !Task.isCancelled else { return }
                            store.searchQuery = value
                        }
                    }
                    .onChange(of: store.searchQuery) { _, value in
                        if searchText != value { searchText = value }
                    }
                if !store.searchQuery.isEmpty {
                    Button {
                        store.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Pen.inkFaded)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(Pen.inkPrimary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Menu {
                Button("Select Notes", systemImage: "checkmark.circle") {
                    selecting = true
                }
                .disabled(!hasVisibleNotes)

                Button(viewMode == .list ? "View as Gallery" : "View as List",
                       systemImage: viewMode == .list ? "square.grid.2x2" : "list.bullet") {
                    withAnimation(reduceMotion ? nil : Pen.spring) { viewMode = viewMode == .list ? .gallery : .list }
                }

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
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Pen.inkPrimary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.headline)
                    .foregroundStyle(Pen.inkPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(dateLabel(note)).foregroundStyle(Pen.inkFaded)
                    Text(note.preview).foregroundStyle(Pen.inkFaded).lineLimit(1)
                }
                .font(.subheadline)
                if !note.normalizedTags.isEmpty {
                    Text(note.normalizedTags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Pen.inkAccent)
                        .lineLimit(1)
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
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                .tint(Pen.inkPositive)
        } else {
            Button(role: .destructive) {
                store.deleteNote(note.id)
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
            Text("\(noteCount) notes in this space")
                .font(Pen.caption).foregroundStyle(Pen.inkFaded)
        }
        .padding(16)
        .background(Pen.paperRaised)
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
                .font(.footnote).foregroundStyle(Pen.inkFaded)
            Spacer()
            Button(isTrash ? "Delete" : "Delete", role: .destructive) {
                confirmDeleteSelected = true
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Pen.paperRaised)
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
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Empty state

    private var emptyState: some View {
        let searching = !store.searchQuery.isEmpty
        return VStack(spacing: 16) {
            Image(systemName: searching ? "magnifyingglass" : (isTrash ? "trash" : "pencil.and.outline"))
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Pen.inkAccent)
                .frame(width: 80, height: 80)
                .background(Pen.accentWash, in: RoundedRectangle(cornerRadius: 24))
            Text(searching ? "No matching thoughts" : (isTrash ? "Nothing here for now" : "A little room to think"))
                .font(.system(.title2, design: .serif)).foregroundStyle(Pen.inkPrimary)
            Text(searching ? "Try a different title or tag." : (isTrash ? "Deleted notes will appear here." : "Start with a question, a sketch, or whatever is on your mind."))
                .font(Pen.sub).foregroundStyle(Pen.inkFaded)
                .multilineTextAlignment(.center)
            if searching {
                Button("Clear search") { store.searchQuery = "" }
                    .buttonStyle(PenQuietButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pen.paperRaised)
    }

    // MARK: Grouping

    private struct NoteGroup { let title: String; let notes: [Note] }

    private func groupedNotes(from notes: [Note]) -> [NoteGroup] {
        let cal = Calendar.current
        let pinned = notes.filter(\.pinned)
        let unpinned = notes.filter { !$0.pinned }
        var today: [Note] = []
        var yesterday: [Note] = []
        var previous7: [Note] = []
        var monthBuckets: [(String, [Note])] = []
        var yearBuckets: [(String, [Note])] = []

        let monthFormatter = DateFormatter(); monthFormatter.dateFormat = "MMMM"
        let yearFormatter = DateFormatter(); yearFormatter.dateFormat = "yyyy"

        // Group by creation date so sections always match the (stable,
        // created-newest-first) list order — editing a note no longer moves it.
        for note in unpinned {
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
        if !pinned.isEmpty { groups.append(.init(title: "Pinned", notes: pinned)) }
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
