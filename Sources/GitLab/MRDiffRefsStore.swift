import Foundation

/// Coalesces and caches `diff_refs` lookups per (directory, MR IID). The diff
/// pipeline (`fetchChangedFiles` then N × `fetchUnifiedDiff` for the same MR)
/// would otherwise call `glab api` once per file. The actor stores both the
/// in-flight `Task` (so concurrent waiters share one network call) and the
/// resolved value (so subsequent reads within the same session are free).
///
/// Stale-on-push: call `invalidate` from the diff window's reload path so a
/// fresh push to the MR is picked up on the next refresh.
actor MRDiffRefsStore {
    static let shared = MRDiffRefsStore()

    private struct Key: Hashable {
        let directory: String
        let iid: Int
    }

    private var inflight: [Key: Task<MRDiffRefs, Error>] = [:]
    private var cached: [Key: MRDiffRefs] = [:]

    func refs(iid: Int, directory: String) async throws -> MRDiffRefs {
        let key = Key(directory: directory, iid: iid)
        if let hit = cached[key] {
            return hit
        }
        if let existing = inflight[key] {
            return try await existing.value
        }
        let task = Task<MRDiffRefs, Error> {
            try await fetchMRDiffRefs(mrIID: iid, directory: directory)
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

    func invalidate(iid: Int, directory: String) {
        let key = Key(directory: directory, iid: iid)
        cached[key] = nil
        inflight[key] = nil
    }
}
