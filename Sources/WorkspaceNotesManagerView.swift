import AppKit
import SwiftUI

struct WorkspaceNotesManagerView: View {
    @ObservedObject private var store = WorkspaceNotesStore.shared
    @State private var selection: Selection? = nil
    @State private var liveWorkspaces: [AppDelegate.WorkspaceListEntry] = []
    @State private var draftTitle: String = ""
    @State private var draftContent: String = ""
    @State private var draftIsCompleted: Bool = false

    enum Selection: Hashable {
        case active(workspaceId: UUID, noteId: UUID)
        case archived(noteId: UUID)
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 300)
            detail
                .frame(minWidth: 360)
        }
        .frame(minWidth: 640, minHeight: 380)
        .onAppear {
            store.loadIfNeeded()
            refreshLiveWorkspaces()
            if selection == nil { selectFirstAvailable() }
            loadDraftFromSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceNotesDidChange)) { _ in
            // Selection might point to a deleted note; clear if so.
            if let selection, !selectionStillExists(selection) {
                self.selection = nil
            }
            refreshLiveWorkspaces()
            loadDraftFromSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mainWindowContextsDidChange)) { _ in
            refreshLiveWorkspaces()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            activeSection
            archivedSection
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var activeSection: some View {
        let groups = activeGroups()
        Section(String(localized: "notes.manager.section.active", defaultValue: "Active workspaces")) {
            if groups.isEmpty {
                Text(String(localized: "notes.manager.empty.active", defaultValue: "No notes in open workspaces"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(groups, id: \.workspaceId) { group in
                    DisclosureGroup(group.title) {
                        ForEach(group.notes) { note in
                            HStack {
                                Image(systemName: note.isCompleted ? "checkmark.square.fill" : "square")
                                    .foregroundColor(note.isCompleted ? .accentColor : .secondary)
                                Text(displayTitle(note))
                                    .lineLimit(1)
                            }
                            .tag(Selection.active(workspaceId: group.workspaceId, noteId: note.id))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var archivedSection: some View {
        Section(String(localized: "notes.manager.section.archived", defaultValue: "Archived")) {
            if store.archived.isEmpty {
                Text(String(localized: "notes.manager.empty.archived", defaultValue: "No archived notes"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.archived) { entry in
                    HStack {
                        Image(systemName: "archivebox")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayTitle(entry.note))
                                .lineLimit(1)
                            Text(entry.originalWorkspaceTitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(Selection.archived(noteId: entry.id))
                }
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            switch selection {
            case .active(let workspaceId, let noteId):
                if let note = activeNote(workspaceId: workspaceId, noteId: noteId) {
                    activeDetail(workspaceId: workspaceId, note: note)
                } else {
                    placeholder
                }
            case .archived(let noteId):
                if let entry = store.archived.first(where: { $0.id == noteId }) {
                    archivedDetail(entry: entry)
                } else {
                    placeholder
                }
            case .none:
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var placeholder: some View {
        VStack {
            Spacer()
            Text(String(localized: "notes.manager.empty.title", defaultValue: "No note selected"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(String(localized: "notes.manager.empty.subtitle", defaultValue: "Pick a note from the sidebar."))
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func activeDetail(workspaceId: UUID, note: WorkspaceNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                String(localized: "notes.manager.titlePlaceholder", defaultValue: "Title"),
                text: $draftTitle
            )
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .onChange(of: draftTitle) { _ in commitDraft(workspaceId: workspaceId, noteId: note.id) }

            TextEditor(text: $draftContent)
                .font(.body)
                .frame(minHeight: 120)
                .border(Color(nsColor: .separatorColor))
                .onChange(of: draftContent) { _ in commitDraft(workspaceId: workspaceId, noteId: note.id) }

            HStack(spacing: 12) {
                Toggle(String(localized: "notes.manager.completed", defaultValue: "Completed"), isOn: $draftIsCompleted)
                    .onChange(of: draftIsCompleted) { _ in commitDraft(workspaceId: workspaceId, noteId: note.id) }
                Spacer()
                Text(formattedDate(note.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "notes.manager.archiveSingle", defaultValue: "Archive")) {
                    archiveSingle(workspaceId: workspaceId, noteId: note.id)
                }
                Button(String(localized: "common.delete", defaultValue: "Delete"), role: .destructive) {
                    deleteActiveNote(workspaceId: workspaceId, note: note)
                }
                .tint(.red)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func archivedDetail(entry: ArchivedWorkspaceNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayTitle(entry.note))
                .font(.title3.weight(.semibold))
            Text(entry.note.content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Label(entry.originalWorkspaceTitle, systemImage: "archivebox")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formattedDate(entry.archivedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                Menu(String(localized: "notes.manager.restoreTo", defaultValue: "Restore to…")) {
                    if liveWorkspaces.isEmpty {
                        Button(String(localized: "notes.manager.noLiveWorkspaces", defaultValue: "No open workspaces")) {}
                            .disabled(true)
                    } else {
                        ForEach(liveWorkspaces) { entryWs in
                            Button {
                                _ = store.restoreArchived(id: entry.id, to: entryWs.id)
                                selection = .active(workspaceId: entryWs.id, noteId: entry.id)
                            } label: {
                                if entry.originalWorkspaceId == entryWs.id {
                                    Label(entryWs.title, systemImage: "arrow.uturn.backward")
                                } else {
                                    Text(entryWs.title)
                                }
                            }
                        }
                    }
                }
                Button(String(localized: "common.delete", defaultValue: "Delete"), role: .destructive) {
                    confirmDeleteArchived(ids: [entry.id])
                }
                .tint(.red)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private struct ActiveGroup {
        let workspaceId: UUID
        let title: String
        let notes: [WorkspaceNote]
        let isLive: Bool
    }

    private func activeGroups() -> [ActiveGroup] {
        let liveById = Dictionary(uniqueKeysWithValues: liveWorkspaces.map { ($0.id, $0.title) })
        var groups: [ActiveGroup] = []
        for (workspaceId, notes) in store.notesByWorkspaceId {
            guard !notes.isEmpty else { continue }
            let title: String
            let isLive: Bool
            if let liveTitle = liveById[workspaceId] {
                title = liveTitle
                isLive = true
            } else if let lastKnown = store.lastKnownTitle(for: workspaceId) {
                title = String(
                    format: String(
                        localized: "notes.manager.inactivePrefix.format",
                        defaultValue: "Inactive: %@"
                    ),
                    lastKnown
                )
                isLive = false
            } else {
                title = String(
                    localized: "notes.manager.unknownWorkspace",
                    defaultValue: "Unknown workspace"
                )
                isLive = false
            }
            groups.append(ActiveGroup(workspaceId: workspaceId, title: title, notes: notes, isLive: isLive))
        }
        groups.sort { lhs, rhs in
            // Live workspaces first, then alphabetical.
            if lhs.isLive != rhs.isLive { return lhs.isLive }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return groups
    }

    private func activeNote(workspaceId: UUID, noteId: UUID) -> WorkspaceNote? {
        store.notesByWorkspaceId[workspaceId]?.first(where: { $0.id == noteId })
    }

    private func displayTitle(_ note: WorkspaceNote) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = note.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if !firstLine.isEmpty { return firstLine }
        return String(localized: "notes.manager.untitled", defaultValue: "Untitled")
    }

    private func selectFirstAvailable() {
        if let first = activeGroups().first, let firstNote = first.notes.first {
            selection = .active(workspaceId: first.workspaceId, noteId: firstNote.id)
            return
        }
        if let first = store.archived.first {
            selection = .archived(noteId: first.id)
        }
    }

    private func selectionStillExists(_ selection: Selection) -> Bool {
        switch selection {
        case .active(let workspaceId, let noteId):
            return activeNote(workspaceId: workspaceId, noteId: noteId) != nil
        case .archived(let noteId):
            return store.archived.contains(where: { $0.id == noteId })
        }
    }

    private func loadDraftFromSelection() {
        switch selection {
        case .active(let workspaceId, let noteId):
            if let note = activeNote(workspaceId: workspaceId, noteId: noteId) {
                draftTitle = note.title
                draftContent = note.content
                draftIsCompleted = note.isCompleted
            }
        default:
            draftTitle = ""
            draftContent = ""
            draftIsCompleted = false
        }
    }

    private func commitDraft(workspaceId: UUID, noteId: UUID) {
        guard let original = activeNote(workspaceId: workspaceId, noteId: noteId) else { return }
        guard original.title != draftTitle
            || original.content != draftContent
            || original.isCompleted != draftIsCompleted else { return }
        var updated = original
        updated.title = draftTitle
        updated.content = draftContent
        updated.isCompleted = draftIsCompleted
        store.updateNote(updated, for: workspaceId)
    }

    private func archiveSingle(workspaceId: UUID, noteId: UUID) {
        guard let note = activeNote(workspaceId: workspaceId, noteId: noteId) else { return }
        let title = liveWorkspaces.first(where: { $0.id == workspaceId })?.title
            ?? String(localized: "notes.manager.unknownWorkspace", defaultValue: "Unknown workspace")
        // Archive only this single note: set notes to remaining + push entry into archived.
        let remaining = (store.notesByWorkspaceId[workspaceId] ?? []).filter { $0.id != noteId }
        store.setNotes(remaining, for: workspaceId)
        // Build a one-off archived entry by piggybacking on archiveNotes via a temp store path.
        // Simpler: append directly through store API for single note.
        store.archiveSingleNote(note, originalWorkspaceId: workspaceId, originalWorkspaceTitle: title)
        selection = .archived(noteId: noteId)
    }

    private func deleteActiveNote(workspaceId: UUID, note: WorkspaceNote) {
        store.removeNote(id: note.id, for: workspaceId)
        selection = nil
    }

    private func confirmDeleteArchived(ids: [UUID]) {
        if ids.count <= 1 {
            store.deleteArchived(ids: ids)
            selection = nil
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "notes.manager.deleteArchived.title.format",
                defaultValue: "Delete %lld archived notes?"
            ),
            ids.count
        )
        alert.informativeText = String(
            localized: "notes.manager.deleteArchived.message",
            defaultValue: "This cannot be undone."
        )
        alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.deleteArchived(ids: ids)
            selection = nil
        }
    }

    private func refreshLiveWorkspaces() {
        liveWorkspaces = AppDelegate.shared?.liveWorkspaceListSnapshot() ?? []
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
