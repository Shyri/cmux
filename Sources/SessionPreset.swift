import Foundation

/// Named session preset: a saved snapshot of every open window/workspace/layout
/// the user can re-apply on demand. Independent of the anonymous autosave used
/// for restore-on-launch.
struct SessionPreset: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    let createdAt: TimeInterval
    var updatedAt: TimeInterval
    var snapshot: AppSessionSnapshot

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        snapshot: AppSessionSnapshot
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.snapshot = snapshot
    }

    static func == (lhs: SessionPreset, rhs: SessionPreset) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.createdAt == rhs.createdAt &&
            lhs.updatedAt == rhs.updatedAt
    }
}

enum SessionPresetSchema {
    static let fileExtension = "cmuxpreset"
    static let directoryName = "presets"

    /// `~/Library/Application Support/cmux/presets-<safeBundleId>/`. Separated
    /// per-bundle-id so cmux and Chatmux keep independent preset collections.
    static func defaultDirectoryURL(
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
            .appendingPathComponent("\(directoryName)-\(safeBundleId)", isDirectory: true)
    }
}

extension SessionPreset {
    /// Stable JSON encoding used both for storage and for preset-vs-snapshot
    /// equality comparisons (see `AppSessionSnapshot.canonicalEncoded`).
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension AppSessionSnapshot {
    /// Returns a stable byte representation of *just* the windows array. Used
    /// to detect whether the live session has drifted from a loaded preset.
    /// `version` and `createdAt` are intentionally excluded.
    func canonicalWindowsEncoded() -> Data? {
        try? SessionPreset.canonicalEncoder().encode(windows)
    }
}
