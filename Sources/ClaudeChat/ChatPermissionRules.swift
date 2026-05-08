import Foundation

/// Parses Claude Code's `permissions.allow` / `permissions.deny` patterns
/// and decides whether a given (toolName, input) pair is auto-allowed,
/// auto-denied, or should fall through to the inline UI.
///
/// Pattern syntax (mirrors Claude Code):
///   - `ToolName`                    → matches any input for that tool
///   - `ToolName(exact)`             → matches when the tool's primary
///                                     argument equals `exact`
///   - `ToolName(prefix:*)`          → matches when the argument starts
///                                     with `prefix` (followed by space,
///                                     slash or end of string)
///   - `ToolName(glob/with/**)`      → matches when the argument matches
///                                     the glob (** = any subpath, * = any
///                                     non-slash chars)
///
/// The "primary argument" is selected per-tool (best effort):
///   - Bash → `command`
///   - Edit / MultiEdit / Write / Read / NotebookEdit → `file_path`
///   - Glob / Grep → `pattern`
///   - WebFetch → `url`
///   - WebSearch → `query`
///   - Anything else → no argument matching, so `Tool(...)` won't match
struct ChatPermissionRules {
    enum Decision: Equatable {
        case allow
        case deny
        case ask
    }

    let allow: [ChatPermissionPattern]
    let deny: [ChatPermissionPattern]

    static let empty = ChatPermissionRules(allow: [], deny: [])

    func decide(toolName: String, input: [String: Any]) -> Decision {
        if deny.contains(where: { $0.matches(toolName: toolName, input: input) }) {
            return .deny
        }
        if allow.contains(where: { $0.matches(toolName: toolName, input: input) }) {
            return .allow
        }
        return .ask
    }

    /// Load rules from the standard Claude Code locations, in priority
    /// order (local-project deny > shared-project deny > global deny;
    /// then local-project allow > shared > global).
    ///
    /// Files that do not exist or cannot be parsed are silently skipped.
    static func load(workingDirectory: String) -> ChatPermissionRules {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let candidatePaths: [String] = [
            (workingDirectory as NSString).appendingPathComponent(".claude/settings.local.json"),
            (workingDirectory as NSString).appendingPathComponent(".claude/settings.json"),
            homeURL.appendingPathComponent(".claude/settings.json").path
        ]

        var allow: [ChatPermissionPattern] = []
        var deny: [ChatPermissionPattern] = []
        for path in candidatePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let permissions = json["permissions"] as? [String: Any]
            else { continue }
            if let allowList = permissions["allow"] as? [String] {
                allow.append(contentsOf: allowList.compactMap(ChatPermissionPattern.parse))
            }
            if let denyList = permissions["deny"] as? [String] {
                deny.append(contentsOf: denyList.compactMap(ChatPermissionPattern.parse))
            }
        }
        return ChatPermissionRules(allow: allow, deny: deny)
    }

    /// Append `pattern` to `permissions.allow` in the file at `path`,
    /// creating the file/directory if needed. No-op if `pattern` is
    /// already present. Other keys in the file are preserved.
    static func writeAllowEntry(_ pattern: String, toFileAt path: String) throws {
        var json = readJSON(path) ?? [:]
        var permissions = (json["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        if !allow.contains(pattern) {
            allow.append(pattern)
        }
        permissions["allow"] = allow
        json["permissions"] = permissions
        try writeJSON(json, path: path)
    }

    /// Remove `pattern` from `permissions.allow` in the file at `path`.
    /// No-op if the file does not exist or the pattern is absent.
    static func removeAllowEntry(_ pattern: String, fromFileAt path: String) throws {
        guard var json = readJSON(path),
              var permissions = json["permissions"] as? [String: Any],
              var allow = permissions["allow"] as? [String]
        else { return }
        allow.removeAll { $0 == pattern }
        permissions["allow"] = allow
        json["permissions"] = permissions
        try writeJSON(json, path: path)
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func writeJSON(_ json: [String: Any], path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

struct ChatPermissionPattern {
    let toolName: String
    /// nil → match any invocation of `toolName`. Non-nil → match the
    /// primary argument against this spec.
    let argument: String?

    static func parse(_ raw: String) -> ChatPermissionPattern? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let openParen = s.firstIndex(of: "("), s.last == ")" {
            let tool = String(s[..<openParen]).trimmingCharacters(in: .whitespaces)
            let argStart = s.index(after: openParen)
            let argEnd = s.index(before: s.endIndex)
            let arg = String(s[argStart..<argEnd])
            return ChatPermissionPattern(toolName: tool, argument: arg)
        }
        return ChatPermissionPattern(toolName: s, argument: nil)
    }

    func matches(toolName: String, input: [String: Any]) -> Bool {
        guard self.toolName == toolName else { return false }
        guard let argument else { return true }
        guard let target = ChatPermissionPattern.primaryArgument(toolName: toolName, input: input) else {
            return false
        }
        return ChatPermissionPattern.match(pattern: argument, against: target)
    }

    private static func primaryArgument(toolName: String, input: [String: Any]) -> String? {
        switch toolName {
        case "Bash":
            return input["command"] as? String
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return input["file_path"] as? String
        case "Glob", "Grep":
            return input["pattern"] as? String
        case "WebFetch":
            return input["url"] as? String
        case "WebSearch":
            return input["query"] as? String
        default:
            return nil
        }
    }

    private static func match(pattern: String, against value: String) -> Bool {
        if pattern.hasSuffix(":*") {
            let prefix = String(pattern.dropLast(2))
            if value == prefix { return true }
            // For Bash: "git status:*" matches "git status", "git status -s", "git status foo".
            if value.hasPrefix(prefix + " ") { return true }
            // For paths: "src:*" matches "src/foo", "src/bar/baz".
            if value.hasPrefix(prefix + "/") { return true }
            return false
        }
        if pattern.contains("*") {
            return globMatch(pattern: pattern, value: value)
        }
        return pattern == value
    }

    private static func globMatch(pattern: String, value: String) -> Bool {
        // Translate a minimal glob into a regex:
        //   "**"  → ".*"
        //   "*"   → "[^/]*"
        //   "."   → "\\."
        //   anything else → literal
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            if ch == "*" {
                let nextIdx = pattern.index(after: i)
                if nextIdx < pattern.endIndex, pattern[nextIdx] == "*" {
                    regex += ".*"
                    i = pattern.index(after: nextIdx)
                    continue
                } else {
                    regex += "[^/]*"
                    i = pattern.index(after: i)
                    continue
                }
            }
            // Escape regex meta-characters.
            let escaped = ".+?()[]|{}^$\\".contains(ch)
            if escaped {
                regex += "\\\(ch)"
            } else {
                regex += String(ch)
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        guard let re = try? NSRegularExpression(pattern: regex) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return re.firstMatch(in: value, range: range) != nil
    }
}
