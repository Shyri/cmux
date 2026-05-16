import Foundation
import SwiftUI

/// Notification posted whenever the preset collection or active preset changes.
extension Notification.Name {
    static let sessionPresetsDidChange = Notification.Name("cmux.sessionPresetsDidChange")
}

@MainActor
final class SessionPresetStore: ObservableObject {
    static let shared = SessionPresetStore()

    @Published private(set) var presets: [SessionPreset] = []
    @Published private(set) var activePresetId: UUID?

    private let directoryURL: URL?
    private let activePresetIdDefaultsKey = "sessionPresets.activeId"
    private var hasLoaded = false

    init(
        directoryURL: URL? = SessionPresetSchema.defaultDirectoryURL(),
        defaults: UserDefaults = .standard
    ) {
        self.directoryURL = directoryURL
        if let stored = defaults.string(forKey: activePresetIdDefaultsKey), let id = UUID(uuidString: stored) {
            self.activePresetId = id
        }
    }

    // MARK: - Lifecycle

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    func reload() {
        guard let directoryURL else {
            presets = []
            return
        }
        ensureDirectoryExists()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            presets = []
            return
        }

        var loaded: [SessionPreset] = []
        let decoder = JSONDecoder()
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let preset = try? decoder.decode(SessionPreset.self, from: data) else {
                continue
            }
            loaded.append(preset)
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        presets = loaded

        if let activeId = activePresetId, !loaded.contains(where: { $0.id == activeId }) {
            setActive(nil)
        }
        notifyDidChange()
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String, snapshot: AppSessionSnapshot) -> SessionPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preset = SessionPreset(name: trimmed, snapshot: snapshot)
        guard persist(preset) else { return nil }
        presets.append(preset)
        sortPresets()
        notifyDidChange()
        return preset
    }

    @discardableResult
    func rename(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        var updated = presets[index]
        updated.name = trimmed
        updated.updatedAt = Date().timeIntervalSince1970
        guard persist(updated) else { return false }
        presets[index] = updated
        sortPresets()
        notifyDidChange()
        return true
    }

    @discardableResult
    func duplicate(id: UUID) -> SessionPreset? {
        guard let original = presets.first(where: { $0.id == id }) else { return nil }
        let copyName = String(
            format: String(localized: "presets.duplicateName.format", defaultValue: "%@ Copy"),
            original.name
        )
        return create(name: copyName, snapshot: original.snapshot)
    }

    func delete(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if let url = fileURL(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
        presets.remove(at: index)
        if activePresetId == id {
            setActive(nil)
        }
        notifyDidChange()
    }

    @discardableResult
    func update(id: UUID, snapshot: AppSessionSnapshot) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        var updated = presets[index]
        updated.snapshot = snapshot
        updated.updatedAt = Date().timeIntervalSince1970
        guard persist(updated) else { return false }
        presets[index] = updated
        notifyDidChange()
        return true
    }

    func setActive(_ id: UUID?, defaults: UserDefaults = .standard) {
        activePresetId = id
        if let id {
            defaults.set(id.uuidString, forKey: activePresetIdDefaultsKey)
        } else {
            defaults.removeObject(forKey: activePresetIdDefaultsKey)
        }
        notifyDidChange()
    }

    func preset(for id: UUID) -> SessionPreset? {
        presets.first { $0.id == id }
    }

    var activePreset: SessionPreset? {
        guard let activePresetId else { return nil }
        return preset(for: activePresetId)
    }

    // MARK: - Import / Export

    /// Decodes a preset payload from disk. The decoded preset's id is replaced
    /// with a fresh UUID so importing the same file twice yields two presets.
    func importFromURL(_ url: URL) -> SessionPreset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard var imported = try? decoder.decode(SessionPreset.self, from: data) else { return nil }
        imported = SessionPreset(
            id: UUID(),
            name: imported.name,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            snapshot: imported.snapshot
        )
        guard persist(imported) else { return nil }
        presets.append(imported)
        sortPresets()
        notifyDidChange()
        return imported
    }

    func exportToURL(id: UUID, _ destination: URL) -> Bool {
        guard let preset = preset(for: id) else { return false }
        do {
            let data = try SessionPreset.canonicalEncoder().encode(preset)
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internals

    private func ensureDirectoryExists() {
        guard let directoryURL else { return }
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func fileURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    @discardableResult
    private func persist(_ preset: SessionPreset) -> Bool {
        guard let url = fileURL(for: preset.id) else { return false }
        ensureDirectoryExists()
        do {
            let data = try SessionPreset.canonicalEncoder().encode(preset)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func sortPresets() {
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .sessionPresetsDidChange, object: self)
    }
}
