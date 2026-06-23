import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers the per-workspace GitLab issue filter store
/// (milestone / assignee), including the injectable-file persistence
/// round-trip, the "empty filter removes the entry" rule, and the
/// bundle-id-sanitizing default path.
@MainActor
@Suite struct GitLabIssueFiltersStoreTests {
    // MARK: - GitLabIssueFilters value semantics

    @Test func emptyFiltersAreEmpty() {
        #expect(GitLabIssueFilters.empty.isEmpty)
        #expect(GitLabIssueFilters(milestone: "v1", assignee: "").isEmpty == false)
        #expect(GitLabIssueFilters(milestone: "", assignee: "me").isEmpty == false)
    }

    // MARK: - defaultFileURL

    @Test func defaultFileURLSanitizesBundleIdentifier() throws {
        let appSupport = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let url = try #require(GitLabIssueFiltersStore.defaultFileURL(
            bundleIdentifier: "com.cmuxterm.app/weird:id",
            appSupportDirectory: appSupport
        ))
        // Slashes/colons are replaced; the cmux subdir + filename are stable.
        #expect(url.path == "/tmp/appsupport/cmux/gitlab-issue-filters-com.cmuxterm.app_weird_id.json")
    }

    @Test func defaultFileURLFallsBackToCanonicalBundleIdWhenBlank() throws {
        let appSupport = URL(fileURLWithPath: "/tmp/as", isDirectory: true)
        let url = try #require(GitLabIssueFiltersStore.defaultFileURL(
            bundleIdentifier: "  ",
            appSupportDirectory: appSupport
        ))
        #expect(url.lastPathComponent == "gitlab-issue-filters-com.cmuxterm.app.json")
    }

    // MARK: - persistence round-trip

    @Test func setFlushAndReloadPreservesFilters() throws {
        try withTemporaryFile { fileURL in
            let ws = UUID()
            let store = GitLabIssueFiltersStore(fileURL: fileURL)
            store.setFilters(GitLabIssueFilters(milestone: "v1", assignee: "alice"), for: ws)
            store.flush()

            // A fresh store reading the same file sees the saved filters.
            let reloaded = GitLabIssueFiltersStore(fileURL: fileURL)
            let filters = reloaded.filters(for: ws)
            #expect(filters.milestone == "v1")
            #expect(filters.assignee == "alice")
        }
    }

    @Test func settingEmptyFiltersRemovesTheEntry() throws {
        try withTemporaryFile { fileURL in
            let ws = UUID()
            let store = GitLabIssueFiltersStore(fileURL: fileURL)
            store.setFilters(GitLabIssueFilters(milestone: "v1", assignee: ""), for: ws)
            #expect(store.filtersByWorkspaceId[ws] != nil)
            // Clearing back to empty drops the workspace entry entirely.
            store.setFilters(.empty, for: ws)
            #expect(store.filtersByWorkspaceId[ws] == nil)
        }
    }

    @Test func perFieldSettersComposeIntoOneEntry() throws {
        try withTemporaryFile { fileURL in
            let ws = UUID()
            let store = GitLabIssueFiltersStore(fileURL: fileURL)
            store.setMilestoneFilter("sprint-7", for: ws)
            store.setAssigneeFilter("bob", for: ws)
            let filters = store.filters(for: ws)
            #expect(filters.milestone == "sprint-7")
            #expect(filters.assignee == "bob")
        }
    }

    @Test func filtersAreScopedPerWorkspace() throws {
        try withTemporaryFile { fileURL in
            let wsA = UUID(), wsB = UUID()
            let store = GitLabIssueFiltersStore(fileURL: fileURL)
            store.setMilestoneFilter("A", for: wsA)
            store.setMilestoneFilter("B", for: wsB)
            #expect(store.filters(for: wsA).milestone == "A")
            #expect(store.filters(for: wsB).milestone == "B")
            #expect(store.filters(for: UUID()) == .empty)
        }
    }

    @Test func loadIgnoresMismatchedSchemaVersion() throws {
        try withTemporaryFile { fileURL in
            let ws = UUID()
            // Hand-write a payload from a future schema version.
            let future = #"{"schemaVersion":999,"filtersByWorkspaceId":{"\#(ws.uuidString)":{"milestone":"x","assignee":"y"}}}"#
            try future.write(to: fileURL, atomically: true, encoding: .utf8)
            let store = GitLabIssueFiltersStore(fileURL: fileURL)
            // Unknown schema → ignored, so the workspace reads back empty.
            #expect(store.filters(for: ws) == .empty)
        }
    }

    // MARK: - helper

    private func withTemporaryFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitLabIssueFiltersStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("filters.json"))
    }
}
