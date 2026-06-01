import Foundation

/// Caches the `git merge-tree --write-tree` result per (directory, target SHA,
/// head SHA). The merged-tree OID is what GitLab's panel uses as the "right
/// side" of the MR diff: target HEAD vs the merge result. That filtering
/// excludes cherry-picked duplicates (commits with identical patch-id that
/// landed in target via another MR) because the merge recognizes them as
/// already applied and doesn't re-add them.
///
/// Both `fetchChangedFiles` and N × `fetchUnifiedDiff` need the same OID; the
/// actor coalesces concurrent requests and reuses the result across files.
actor MRMergedTreeStore {
    static let shared = MRMergedTreeStore()

    private struct Key: Hashable {
        let directory: String
        let target: String
        let head: String
    }

    private var inflight: [Key: Task<String, Error>] = [:]
    private var cached: [Key: String] = [:]

    func mergedTreeOID(target: String, head: String, directory: String) async throws -> String {
        let key = Key(directory: directory, target: target, head: head)
        if let hit = cached[key] { return hit }
        if let existing = inflight[key] { return try await existing.value }
        let task = Task<String, Error> {
            try await computeMergeTreeOID(target: target, head: head, directory: directory)
        }
        inflight[key] = task
        do {
            let value = try await task.value
            inflight[key] = nil
            cached[key] = value
            return value
        } catch {
            inflight[key] = nil
            throw error
        }
    }

    func invalidate(target: String, head: String, directory: String) {
        cached[Key(directory: directory, target: target, head: head)] = nil
    }

    func invalidateAll(directory: String) {
        cached = cached.filter { $0.key.directory != directory }
    }
}
