import Foundation
import SwiftUI

/// Sentinels shared by `IssuesListView` for "no milestone" / "no assignee".
let kNoMilestoneSentinel = "__none__"
let kNoAssigneeSentinel = "__none__"

struct GitLabIssueFilters: Codable, Equatable {
    var milestone: String
    var assignee: String

    static let empty = GitLabIssueFilters(milestone: "", assignee: "")

    var isEmpty: Bool { milestone.isEmpty && assignee.isEmpty }
}

@MainActor
final class GitLabIssueFiltersStore: ObservableObject {
    static let shared = GitLabIssueFiltersStore()

    @Published private(set) var filtersByWorkspaceId: [UUID: GitLabIssueFilters] = [:]

    private let fileURL: URL?
    private let saveDebounceNanoseconds: UInt64 = 200_000_000
    private var pendingSave: Task<Void, Never>?
    private var hasLoaded = false

    private struct Payload: Codable {
        var schemaVersion: Int
        var filtersByWorkspaceId: [String: GitLabIssueFilters]
    }

    private static let currentSchemaVersion = 1

    init(fileURL: URL? = GitLabIssueFiltersStore.defaultFileURL()) {
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
            .appendingPathComponent("gitlab-issue-filters-\(safeBundleId).json", isDirectory: false)
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
        var converted: [UUID: GitLabIssueFilters] = [:]
        for (key, value) in payload.filtersByWorkspaceId {
            if let id = UUID(uuidString: key) {
                converted[id] = value
            }
        }
        filtersByWorkspaceId = converted
    }

    // MARK: - Reads

    func filters(for workspaceId: UUID) -> GitLabIssueFilters {
        loadIfNeeded()
        return filtersByWorkspaceId[workspaceId] ?? .empty
    }

    // MARK: - Mutations

    func setFilters(_ filters: GitLabIssueFilters, for workspaceId: UUID) {
        loadIfNeeded()
        let current = filtersByWorkspaceId[workspaceId] ?? .empty
        if current == filters { return }
        if filters.isEmpty {
            filtersByWorkspaceId.removeValue(forKey: workspaceId)
        } else {
            filtersByWorkspaceId[workspaceId] = filters
        }
        scheduleSave()
    }

    func setMilestoneFilter(_ value: String, for workspaceId: UUID) {
        var current = filters(for: workspaceId)
        current.milestone = value
        setFilters(current, for: workspaceId)
    }

    func setAssigneeFilter(_ value: String, for workspaceId: UUID) {
        var current = filters(for: workspaceId)
        current.assignee = value
        setFilters(current, for: workspaceId)
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

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard fileURL != nil else { return }
        let payload = makePayload()
        Self.write(payload: payload, to: fileURL)
    }

    private func makePayload() -> Payload {
        let stringKeyed = Dictionary(uniqueKeysWithValues:
            filtersByWorkspaceId.map { ($0.key.uuidString, $0.value) }
        )
        return Payload(
            schemaVersion: Self.currentSchemaVersion,
            filtersByWorkspaceId: stringKeyed
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
            // Best-effort.
        }
    }
}
