import Foundation
import SwiftUI

extension Notification.Name {
    static let workspaceNotesDidChange = Notification.Name("cmux.workspaceNotesDidChange")
}

@MainActor
final class WorkspaceNotesStore: ObservableObject {
    static let shared = WorkspaceNotesStore()

    @Published private(set) var notesByWorkspaceId: [UUID: [WorkspaceNote]] = [:]
    @Published private(set) var archived: [ArchivedWorkspaceNote] = []
    /// Last title we saw associated with a given workspaceId. Survives the
    /// workspace going dormant (preset switches, window close without prompt).
    /// Used by Manage Notes to label orphaned note groups as "Inactive: <title>".
    @Published private(set) var lastKnownTitleByWorkspaceId: [UUID: String] = [:]

    private let fileURL: URL?
    private let saveDebounceNanoseconds: UInt64 = 200_000_000
    private var pendingSave: Task<Void, Never>?
    private var hasLoaded = false

    private struct Payload: Codable {
        var schemaVersion: Int
        var notesByWorkspaceId: [String: [WorkspaceNote]]
        var archived: [ArchivedWorkspaceNote]
        var lastKnownTitleByWorkspaceId: [String: String]?
    }

    private static let currentSchemaVersion = 1

    init(fileURL: URL? = WorkspaceNotesStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    nonisolated static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> URL? {
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("workspace-notes-\(safeBundleId).json", isDirectory: false)
    }

    // MARK: - Lifecycle

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load()
    }

    func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            return
        }
        guard payload.schemaVersion == Self.currentSchemaVersion else { return }
        var converted: [UUID: [WorkspaceNote]] = [:]
        for (key, notes) in payload.notesByWorkspaceId {
            if let id = UUID(uuidString: key) {
                converted[id] = notes
            }
        }
        notesByWorkspaceId = converted
        archived = payload.archived
        var titles: [UUID: String] = [:]
        for (key, value) in payload.lastKnownTitleByWorkspaceId ?? [:] {
            if let id = UUID(uuidString: key) {
                titles[id] = value
            }
        }
        lastKnownTitleByWorkspaceId = titles
    }

    // MARK: - Reads

    func notes(for workspaceId: UUID) -> [WorkspaceNote] {
        loadIfNeeded()
        return notesByWorkspaceId[workspaceId] ?? []
    }

    func notesCount(for workspaceId: UUID) -> Int {
        notes(for: workspaceId).count
    }

    func hasMigratedNotes(for workspaceId: UUID) -> Bool {
        loadIfNeeded()
        return notesByWorkspaceId[workspaceId] != nil
    }

    /// Update the cached label for a workspaceId so Manage Notes can keep
    /// labelling notes whose owning workspace is currently dormant (preset
    /// switch, window close without prompt). Only persists if it changes.
    func recordTitle(_ title: String, for workspaceId: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loadIfNeeded()
        if lastKnownTitleByWorkspaceId[workspaceId] == trimmed { return }
        lastKnownTitleByWorkspaceId[workspaceId] = trimmed
        scheduleSave()
    }

    func lastKnownTitle(for workspaceId: UUID) -> String? {
        loadIfNeeded()
        return lastKnownTitleByWorkspaceId[workspaceId]
    }

    // MARK: - Mutations

    func setNotes(_ notes: [WorkspaceNote], for workspaceId: UUID) {
        loadIfNeeded()
        if notes.isEmpty {
            notesByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            notesByWorkspaceId[workspaceId] = notes
        }
        scheduleSave()
        notifyDidChange()
    }

    func appendNote(_ note: WorkspaceNote, for workspaceId: UUID) {
        loadIfNeeded()
        var current = notesByWorkspaceId[workspaceId] ?? []
        current.append(note)
        notesByWorkspaceId[workspaceId] = current
        scheduleSave()
        notifyDidChange()
    }

    func updateNote(_ note: WorkspaceNote, for workspaceId: UUID) {
        loadIfNeeded()
        guard var current = notesByWorkspaceId[workspaceId],
              let idx = current.firstIndex(where: { $0.id == note.id }) else { return }
        current[idx] = note
        notesByWorkspaceId[workspaceId] = current
        scheduleSave()
        notifyDidChange()
    }

    func removeNote(id: UUID, for workspaceId: UUID) {
        loadIfNeeded()
        guard var current = notesByWorkspaceId[workspaceId] else { return }
        current.removeAll { $0.id == id }
        if current.isEmpty {
            notesByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            notesByWorkspaceId[workspaceId] = current
        }
        scheduleSave()
        notifyDidChange()
    }

    func removeNotes(ids: Set<UUID>, for workspaceId: UUID) {
        loadIfNeeded()
        guard var current = notesByWorkspaceId[workspaceId] else { return }
        current.removeAll { ids.contains($0.id) }
        if current.isEmpty {
            notesByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            notesByWorkspaceId[workspaceId] = current
        }
        scheduleSave()
        notifyDidChange()
    }

    func moveNotes(from source: IndexSet, to destination: Int, for workspaceId: UUID) {
        loadIfNeeded()
        guard var current = notesByWorkspaceId[workspaceId] else { return }
        current.move(fromOffsets: source, toOffset: destination)
        notesByWorkspaceId[workspaceId] = current
        scheduleSave()
        notifyDidChange()
    }

    // MARK: - Archive / restore

    /// Move all notes for the given workspace into `archived`. Idempotent: if
    /// the workspace has no notes, this is a no-op.
    func archiveNotes(for workspaceId: UUID, workspaceTitle: String) {
        loadIfNeeded()
        guard let current = notesByWorkspaceId[workspaceId], !current.isEmpty else { return }
        let now = Date()
        let entries = current.map { note in
            ArchivedWorkspaceNote(
                note: note,
                originalWorkspaceId: workspaceId,
                originalWorkspaceTitle: workspaceTitle,
                archivedAt: now
            )
        }
        archived.append(contentsOf: entries)
        notesByWorkspaceId.removeValue(forKey: workspaceId)
        lastKnownTitleByWorkspaceId.removeValue(forKey: workspaceId)
        flush()
        notifyDidChange()
    }

    /// Archive a single note that has already been removed from active notes
    /// by the caller. Used by the Manage Notes UI's per-note Archive button.
    func archiveSingleNote(
        _ note: WorkspaceNote,
        originalWorkspaceId: UUID,
        originalWorkspaceTitle: String
    ) {
        loadIfNeeded()
        let entry = ArchivedWorkspaceNote(
            note: note,
            originalWorkspaceId: originalWorkspaceId,
            originalWorkspaceTitle: originalWorkspaceTitle,
            archivedAt: Date()
        )
        archived.append(entry)
        scheduleSave()
        notifyDidChange()
    }

    /// Discard all notes for the given workspace without archiving.
    func deleteNotes(for workspaceId: UUID) {
        loadIfNeeded()
        guard notesByWorkspaceId[workspaceId] != nil else { return }
        notesByWorkspaceId.removeValue(forKey: workspaceId)
        lastKnownTitleByWorkspaceId.removeValue(forKey: workspaceId)
        flush()
        notifyDidChange()
    }

    func deleteArchived(ids: [UUID]) {
        loadIfNeeded()
        let removeSet = Set(ids)
        archived.removeAll { removeSet.contains($0.id) }
        scheduleSave()
        notifyDidChange()
    }

    /// Returns true if there is at least one archived note whose
    /// `originalWorkspaceId` matches `workspaceId`.
    func hasArchivedNotes(forOriginalWorkspaceId workspaceId: UUID) -> Bool {
        loadIfNeeded()
        return archived.contains { $0.originalWorkspaceId == workspaceId }
    }

    /// Move every archived note whose `originalWorkspaceId` matches
    /// `workspaceId` back into active notes for that workspace. Used when a
    /// session preset restores a workspace that previously had its notes
    /// archived: the latest archived state takes precedence over the inline
    /// (historical) notes embedded in the preset snapshot.
    @discardableResult
    func restoreAllArchivedNotes(for workspaceId: UUID) -> Int {
        loadIfNeeded()
        let matches = archived.filter { $0.originalWorkspaceId == workspaceId }
        guard !matches.isEmpty else { return 0 }
        archived.removeAll { $0.originalWorkspaceId == workspaceId }

        var current = notesByWorkspaceId[workspaceId] ?? []
        let existingIds = Set(current.map { $0.id })
        for entry in matches where !existingIds.contains(entry.id) {
            current.append(entry.note)
        }
        if current.isEmpty {
            notesByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            notesByWorkspaceId[workspaceId] = current
        }
        scheduleSave()
        notifyDidChange()
        return matches.count
    }

    /// Move an archived note into the active notes for `targetWorkspaceId`.
    /// The note's id is preserved.
    @discardableResult
    func restoreArchived(id: UUID, to targetWorkspaceId: UUID) -> Bool {
        loadIfNeeded()
        guard let idx = archived.firstIndex(where: { $0.id == id }) else { return false }
        let entry = archived.remove(at: idx)
        var current = notesByWorkspaceId[targetWorkspaceId] ?? []
        current.append(entry.note)
        notesByWorkspaceId[targetWorkspaceId] = current
        scheduleSave()
        notifyDidChange()
        return true
    }

    // MARK: - Migration

    /// Imports notes for a workspace from the legacy session.json layout —
    /// only when the store has no entry for that id yet. Idempotent.
    func migrateInlineNotesIfNeeded(_ notes: [WorkspaceNote], for workspaceId: UUID) {
        loadIfNeeded()
        guard notesByWorkspaceId[workspaceId] == nil else { return }
        guard !notes.isEmpty else { return }
        notesByWorkspaceId[workspaceId] = notes
        scheduleSave()
        notifyDidChange()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard fileURL != nil else { return }
        pendingSave?.cancel()
        let payload = makePayload()
        let target = fileURL
        let debounce = saveDebounceNanoseconds

        pendingSave = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: debounce)
            if Task.isCancelled { return }
            Self.write(payload: payload, to: target)
        }
    }

    /// Write current state to disk synchronously. Cancels any pending debounced
    /// save and replaces it with an immediate write.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard fileURL != nil else { return }
        let payload = makePayload()
        Self.write(payload: payload, to: fileURL)
    }

    private func makePayload() -> Payload {
        let stringKeyed = Dictionary(uniqueKeysWithValues:
            notesByWorkspaceId.map { ($0.key.uuidString, $0.value) }
        )
        let titlesStringKeyed = Dictionary(uniqueKeysWithValues:
            lastKnownTitleByWorkspaceId.map { ($0.key.uuidString, $0.value) }
        )
        return Payload(
            schemaVersion: Self.currentSchemaVersion,
            notesByWorkspaceId: stringKeyed,
            archived: archived,
            lastKnownTitleByWorkspaceId: titlesStringKeyed
        )
    }

    nonisolated private static func write(payload: Payload, to url: URL?) {
        guard let url else { return }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort. Crash sim test will surface real failures.
        }
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .workspaceNotesDidChange, object: self)
    }
}
