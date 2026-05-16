import Foundation

/// Reads Claude Code's per-session JSONL transcript and the file-history
/// snapshots it stores under `~/.claude/file-history/<sessionId>/`. cmux
/// uses these to power the "undo last turn" button: claude already tracks
/// the file contents for us, we just need to find and copy them back.
enum ClaudeSessionHistory {
    /// File backups captured by Claude Code at the start of a turn — i.e.
    /// the state of each touched file before claude modified it.
    struct TurnFileBackups {
        let sessionId: String
        /// Map of absolute file path → URL of the backup blob inside
        /// `~/.claude/file-history/<sessionId>/`.
        let backups: [String: URL]
    }

    /// Find the latest non-empty `file-history-snapshot` event in the
    /// JSONL for `sessionId` and return the file→backup map. The "latest"
    /// snapshot represents the pre-state of the most recent turn that
    /// touched files.
    static func latestTurnBackups(
        sessionId: String,
        cwd: String
    ) -> TurnFileBackups? {
        guard let jsonlURL = transcriptURL(sessionId: sessionId, cwd: cwd),
              let data = try? Data(contentsOf: jsonlURL),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let historyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/file-history", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)

        var latest: [String: URL] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "file-history-snapshot",
                  let snapshot = obj["snapshot"] as? [String: Any],
                  let backups = snapshot["trackedFileBackups"] as? [String: [String: Any]],
                  !backups.isEmpty
            else { continue }

            // Each later snapshot supersedes earlier ones for the same path
            // (Claude Code rewrites the entry as new versions land).
            for (path, info) in backups {
                guard let backupName = info["backupFileName"] as? String else { continue }
                latest[path] = historyDir.appendingPathComponent(backupName)
            }
        }
        guard !latest.isEmpty else { return nil }
        return TurnFileBackups(sessionId: sessionId, backups: latest)
    }

    /// Restore the files in `backups` to disk, replacing whatever is at
    /// each path right now. Returns the paths that were restored
    /// successfully.
    @discardableResult
    static func restore(_ backups: TurnFileBackups) -> [String] {
        var restored: [String] = []
        for (path, backupURL) in backups.backups {
            guard FileManager.default.fileExists(atPath: backupURL.path) else { continue }
            do {
                let data = try Data(contentsOf: backupURL)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                restored.append(path)
            } catch {
                #if DEBUG
                NSLog("ClaudeSessionHistory.restore failed path=\(path) err=\(error.localizedDescription)")
                #endif
            }
        }
        return restored
    }

    // MARK: - Private

    /// Compute the path of the JSONL transcript for a session given the
    /// chat's cwd. Claude Code stores transcripts under
    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where the
    /// encoded cwd replaces `/` with `-` and prefixes with `-`.
    private static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let encoded = encodeCwd(cwd)
        guard !encoded.isEmpty else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    private static func encodeCwd(_ path: String) -> String {
        // Mirror Claude Code's filename convention: strip trailing slashes,
        // then replace every `/` with `-` (the leading slash becomes a
        // leading `-` so the result matches `-Users-shyri-...`).
        let trimmed = path.trimmingCharacters(in: .init(charactersIn: "/"))
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        return "-" + encoded
    }
}
