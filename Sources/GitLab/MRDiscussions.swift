import Foundation
import SwiftUI
import AppKit

// MARK: - Models

struct MRNote: Identifiable, Equatable, Sendable {
    let id: Int
    let authorName: String
    let authorUsername: String
    let body: String
    let createdAt: Date?
    let resolvable: Bool
    let resolved: Bool
}

/// A GitLab discussion thread attached to a diff position, with one or more
/// notes (replies). Only discussions anchored to a line (`position != nil`)
/// are modeled — other notes are MR-level and not shown inline.
struct MRDiscussion: Identifiable, Equatable, Sendable {
    let id: String
    let notes: [MRNote]
    let filePath: String?
    let oldLine: Int?
    let newLine: Int?

    var resolved: Bool {
        notes.allSatisfy { !$0.resolvable || $0.resolved }
    }

    var isPositioned: Bool { oldLine != nil || newLine != nil }
}

// MARK: - JSON decoding (glab api ... /discussions)

private struct GLDiscussionAuthor: Decodable {
    let name: String?
    let username: String?
}

private struct GLDiscussionPosition: Decodable {
    let old_path: String?
    let new_path: String?
    let old_line: Int?
    let new_line: Int?
}

private struct GLDiscussionNote: Decodable {
    let id: Int
    let body: String?
    let author: GLDiscussionAuthor?
    let created_at: String?
    let resolvable: Bool?
    let resolved: Bool?
    let position: GLDiscussionPosition?
    let system: Bool?
}

private struct GLDiscussion: Decodable {
    let id: String
    let notes: [GLDiscussionNote]?
}

// MARK: - MR Overview (description + author)

struct MROverview: Equatable, Sendable {
    let title: String
    let description: String
    let authorName: String
    let authorUsername: String
    let createdAt: Date?
    let webURL: String
}

private struct GLMROverviewResponse: Decodable {
    struct Author: Decodable {
        let name: String?
        let username: String?
    }
    let title: String?
    let description: String?
    let author: Author?
    let created_at: String?
    let web_url: String?
}

/// Fetches the MR title/description/author via `glab api projects/:id/merge_requests/<iid>`.
/// Used by the diff Overview pane to show context above the comments timeline.
func fetchMROverview(mrIID: Int, directory: String) async throws -> MROverview {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try runGlabMROverview(mrIID: mrIID, directory: directory)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func runGlabMROverview(mrIID: Int, directory: String) throws -> MROverview {
    guard let glabPath = findGlabBinary() else {
        throw MRDiscussionsFetchError.glabNotFound
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "api",
        "projects/:id/merge_requests/\(mrIID)",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        throw MRDiscussionsFetchError.processError(errStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let decoded = try JSONDecoder().decode(GLMROverviewResponse.self, from: outData)
    return MROverview(
        title: decoded.title ?? "",
        description: decoded.description ?? "",
        authorName: decoded.author?.name ?? "",
        authorUsername: decoded.author?.username ?? "",
        createdAt: parseISO(decoded.created_at),
        webURL: decoded.web_url ?? ""
    )
}

// MARK: - Fetcher

enum MRDiscussionsFetchError: Error, Sendable {
    case glabNotFound
    case processError(String)
    case parseError
}

/// Runs `glab api projects/:id/merge_requests/<iid>/discussions --paginate`
/// and returns the subset of discussions that have a `position` (inline
/// discussions). MR-level comments are ignored for this iteration.
func fetchMRDiscussions(mrIID: Int, directory: String) async throws -> [MRDiscussion] {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try runGlabDiscussions(mrIID: mrIID, directory: directory)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func runGlabDiscussions(mrIID: Int, directory: String) throws -> [MRDiscussion] {
    guard let glabPath = findGlabBinary() else {
        throw MRDiscussionsFetchError.glabNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: glabPath)
    process.arguments = [
        "api",
        "--paginate",
        "projects/:id/merge_requests/\(mrIID)/discussions",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    var env = ProcessInfo.processInfo.environment
    env["NO_COLOR"] = "1"
    process.environment = env

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let (outData, errData) = drainPipesInParallel(stdout: stdout, stderr: stderr)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        throw MRDiscussionsFetchError.processError(errStr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard !outData.isEmpty else { return [] }

    // When `--paginate` follows the Link header it concatenates multiple JSON
    // arrays back-to-back, e.g. `[...][...]`. Try to decode as one array
    // first; if that fails, split and merge.
    let decoder = JSONDecoder()
    var decoded: [GLDiscussion] = []
    if let single = try? decoder.decode([GLDiscussion].self, from: outData) {
        decoded = single
    } else {
        for chunk in splitConcatenatedJSONArrays(outData) {
            if let page = try? decoder.decode([GLDiscussion].self, from: chunk) {
                decoded.append(contentsOf: page)
            }
        }
    }

    return decoded.compactMap(convert(_:))
}

private func convert(_ d: GLDiscussion) -> MRDiscussion? {
    let rawNotes = d.notes ?? []
    guard let first = rawNotes.first else { return nil }
    // Skip fully system-generated discussions ("assigned to", "approved", …).
    if rawNotes.allSatisfy({ $0.system == true }) { return nil }
    let pos = first.position
    let notes: [MRNote] = rawNotes.compactMap { n in
        // Drop individual system notes that may be mixed in with user replies.
        guard n.system != true else { return nil }
        return MRNote(
            id: n.id,
            authorName: n.author?.name ?? "",
            authorUsername: n.author?.username ?? "",
            body: n.body ?? "",
            createdAt: parseISO(n.created_at),
            resolvable: n.resolvable ?? false,
            resolved: n.resolved ?? false
        )
    }
    guard !notes.isEmpty else { return nil }
    return MRDiscussion(
        id: d.id,
        notes: notes,
        filePath: pos?.new_path ?? pos?.old_path,
        oldLine: pos?.old_line,
        newLine: pos?.new_line
    )
}

// MARK: - Helpers

private func parseISO(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = fmt.date(from: raw) { return d }
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.date(from: raw)
}

/// `glab api --paginate` concatenates page JSON arrays: `[...][...]`. This
/// splits them by tracking bracket depth and returns each top-level array
/// as its own `Data`.
private func splitConcatenatedJSONArrays(_ data: Data) -> [Data] {
    var results: [Data] = []
    var depth = 0
    var start: Int? = nil
    var inString = false
    var escape = false
    let bytes = [UInt8](data)
    for (i, b) in bytes.enumerated() {
        if inString {
            if escape { escape = false; continue }
            if b == 0x5C /* \ */ { escape = true; continue }
            if b == 0x22 /* " */ { inString = false }
            continue
        }
        if b == 0x22 { inString = true; continue }
        if b == 0x5B /* [ */ {
            if depth == 0 { start = i }
            depth += 1
        } else if b == 0x5D /* ] */ {
            depth -= 1
            if depth == 0, let s = start {
                results.append(Data(bytes[s...i]))
                start = nil
            }
        }
    }
    return results
}

// MARK: - Markdown rendering

/// Block-level Markdown renderer. SwiftUI's `Text` can render inline Markdown
/// (bold/italic/code/links) via `AttributedString`, but it ignores block
/// constructs like headings, lists, fenced code blocks, and blockquotes. This
/// view splits the input into blocks and renders each with the appropriate
/// SwiftUI primitive so MR descriptions and comments look right.
struct MarkdownText: View {
    let source: String
    var baseFontSize: CGFloat = 12

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    private func headingFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 6
        case 2: return baseFontSize + 4
        case 3: return baseFontSize + 2
        default: return baseFontSize + 1
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(renderMarkdownInline(text))
                .font(.system(size: headingFontSize(level: level), weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(renderMarkdownInline(text))
                .font(.system(size: baseFontSize))
                .foregroundStyle(Color(nsColor: .labelColor))
                .tint(.accentColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .blockquote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 2)
                Text(renderMarkdownInline(text))
                    .font(.system(size: baseFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .codeBlock(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: baseFontSize - 1, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: NSColor(white: 1, alpha: 0.05)))
            )

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(.system(size: baseFontSize))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(renderMarkdownInline(item))
                            .font(.system(size: baseFontSize))
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .tint(.accentColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .horizontalRule:
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case blockquote(String)
    case codeBlock(code: String, language: String?)
    case list(items: [String], ordered: Bool)
    case horizontalRule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var idx = 0
        var paragraphBuf: [String] = []
        var quoteBuf: [String] = []
        var listBuf: [String] = []
        var listOrdered: Bool? = nil

        func flushParagraph() {
            if !paragraphBuf.isEmpty {
                blocks.append(.paragraph(paragraphBuf.joined(separator: "\n")))
                paragraphBuf.removeAll()
            }
        }
        func flushQuote() {
            if !quoteBuf.isEmpty {
                blocks.append(.blockquote(quoteBuf.joined(separator: "\n")))
                quoteBuf.removeAll()
            }
        }
        func flushList() {
            if !listBuf.isEmpty, let ordered = listOrdered {
                blocks.append(.list(items: listBuf, ordered: ordered))
                listBuf.removeAll()
                listOrdered = nil
            }
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        while idx < lines.count {
            let raw = lines[idx]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if line.hasPrefix("```") {
                flushAll()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                idx += 1
                var codeLines: [String] = []
                while idx < lines.count {
                    let cur = lines[idx]
                    if cur.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        idx += 1
                        break
                    }
                    codeLines.append(cur)
                    idx += 1
                }
                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"),
                                         language: lang.isEmpty ? nil : lang))
                continue
            }

            // Horizontal rule
            if line == "---" || line == "***" || line == "___" {
                flushAll()
                blocks.append(.horizontalRule)
                idx += 1
                continue
            }

            // Heading
            if let match = headingMatch(line) {
                flushAll()
                blocks.append(.heading(level: match.level, text: match.text))
                idx += 1
                continue
            }

            // Blank line
            if line.isEmpty {
                flushAll()
                idx += 1
                continue
            }

            // Blockquote
            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                quoteBuf.append(body)
                idx += 1
                continue
            } else if !quoteBuf.isEmpty {
                flushQuote()
            }

            // Unordered list
            if let body = unorderedItem(line) {
                flushParagraph()
                if listOrdered == true { flushList() }
                listOrdered = false
                listBuf.append(body)
                idx += 1
                continue
            }
            // Ordered list
            if let body = orderedItem(line) {
                flushParagraph()
                if listOrdered == false { flushList() }
                listOrdered = true
                listBuf.append(body)
                idx += 1
                continue
            }
            if !listBuf.isEmpty {
                flushList()
            }

            // Default: paragraph line. Preserve original (trimmed only at edges).
            paragraphBuf.append(raw)
            idx += 1
        }
        flushAll()
        return blocks
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
            if level > 6 { return nil }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let after = line.dropFirst(level)
        guard after.first == " " else { return nil }
        let text = after.dropFirst().trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func unorderedItem(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> String? {
        // Match "<digits>. " at the start.
        var i = line.startIndex
        var digitCount = 0
        while i < line.endIndex, line[i].isNumber {
            digitCount += 1
            i = line.index(after: i)
        }
        guard digitCount > 0, i < line.endIndex, line[i] == "." else { return nil }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }
}

/// Inline-only Markdown rendering (bold/italic/code/links). Used inside
/// `MarkdownText` per block.
func renderMarkdownInline(_ raw: String) -> AttributedString {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return AttributedString() }
    do {
        return try AttributedString(
            markdown: trimmed,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )
    } catch {
        return AttributedString(trimmed)
    }
}

// MARK: - SwiftUI card

struct InlineCommentCard: View {
    let discussion: MRDiscussion
    /// When non-nil, the card is wrapped in a `ScrollView` with this height
    /// so very long threads scroll internally instead of pushing the rest of
    /// the diff downward.
    var maxHeight: CGFloat? = nil

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(discussion.notes.enumerated()), id: \.offset) { idx, note in
                if idx > 0 {
                    Divider()
                        .background(Color(nsColor: NSColor(white: 1, alpha: 0.06)))
                }
                noteRow(note)
            }
        }
        .padding(8)

        return Group {
            if let maxHeight {
                ScrollView(.vertical, showsIndicators: true) {
                    inner
                }
                .frame(maxHeight: maxHeight - 4)  // account for outer .vertical padding
            } else {
                inner
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: NSColor(srgbRed: 0x4F/255, green: 0x50/255, blue: 0x52/255, alpha: 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: NSColor(srgbRed: 0x3C/255, green: 0x3C/255, blue: 0x3C/255, alpha: 1)), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func noteRow(_ note: MRNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(initials(for: note))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(authorColor(for: note)))
                Text(note.authorName.isEmpty ? note.authorUsername : note.authorName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if !note.authorUsername.isEmpty && note.authorUsername != note.authorName {
                    Text("@\(note.authorUsername)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let when = note.createdAt {
                    Text(relative(when))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if discussion.resolved {
                    Text("Resolved")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
            }
            MarkdownText(source: note.body, baseFontSize: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func initials(for note: MRNote) -> String {
        let src = note.authorName.isEmpty ? note.authorUsername : note.authorName
        let parts = src.split(separator: " ")
        if let first = parts.first?.first, let second = parts.dropFirst().first?.first {
            return "\(first)\(second)".uppercased()
        }
        return String(src.prefix(2)).uppercased()
    }

    private func authorColor(for note: MRNote) -> Color {
        let src = note.authorName.isEmpty ? note.authorUsername : note.authorName
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan]
        let hash = abs(src.hashValue)
        return palette[hash % palette.count].opacity(0.8)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Binary lookup

private func findGlabBinary() -> String? {
    let candidates = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let full = "\(dir)/glab"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
    }
    for dir in candidates {
        let full = "\(dir)/glab"
        if FileManager.default.isExecutableFile(atPath: full) { return full }
    }
    return nil
}
