import Foundation
import SwiftUI
import AppKit
import MarkdownUI

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
    /// SHAs registered by GitLab for the current MR-version's diff. When set,
    /// callers should anchor `git diff` to these instead of recomputing the
    /// merge-base from live refs — guarantees parity with the panel web view.
    let diffRefs: MRDiffRefs?
}

/// Snapshot of the SHAs GitLab uses for a given MR-version's diff. Mirrors the
/// `diff_refs` object returned by `GET /projects/:id/merge_requests/:iid`.
struct MRDiffRefs: Equatable, Sendable {
    let baseSHA: String
    let headSHA: String
    let startSHA: String
}

private struct GLMROverviewResponse: Decodable {
    struct Author: Decodable {
        let name: String?
        let username: String?
    }
    struct DiffRefs: Decodable {
        let base_sha: String?
        let head_sha: String?
        let start_sha: String?
    }
    let title: String?
    let description: String?
    let author: Author?
    let created_at: String?
    let web_url: String?
    let diff_refs: DiffRefs?
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
        webURL: decoded.web_url ?? "",
        diffRefs: makeDiffRefs(decoded.diff_refs)
    )
}

private func makeDiffRefs(_ raw: GLMROverviewResponse.DiffRefs?) -> MRDiffRefs? {
    guard let raw,
          let base = raw.base_sha, !base.isEmpty,
          let head = raw.head_sha, !head.isEmpty else { return nil }
    return MRDiffRefs(
        baseSHA: base,
        headSHA: head,
        startSHA: raw.start_sha ?? base
    )
}

/// Fetches just the `diff_refs` SHAs for an MR via the same endpoint used by
/// `fetchMROverview`, throwing if the API is unreachable or the MR has no
/// diff_refs (deleted, no commits, etc.). Used by `MRDiffRefsStore` to anchor
/// `git diff` to the exact SHAs GitLab snapshots for the current MR-version.
func fetchMRDiffRefs(mrIID: Int, directory: String) async throws -> MRDiffRefs {
    let overview = try await fetchMROverview(mrIID: mrIID, directory: directory)
    guard let refs = overview.diffRefs else {
        throw MRDiscussionsFetchError.processError(
            "GitLab did not return diff_refs for MR !\(mrIID)"
        )
    }
    return refs
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

// MARK: - Card style

/// Shared chrome for MR description and comment cards: dark background with
/// a subtle 1pt border and rounded corners, matching the reference look.
enum MRCommentCardStyle {
    static let background = Color(nsColor: NSColor(srgbRed: 0x1F/255, green: 0x20/255, blue: 0x24/255, alpha: 1))
    static let border = Color(nsColor: NSColor(srgbRed: 0x33/255, green: 0x36/255, blue: 0x3D/255, alpha: 1))
    static let cornerRadius: CGFloat = 8
    static let innerHorizontalPadding: CGFloat = 16
    static let innerVerticalPadding: CGFloat = 14
}

/// Color used for handle/timestamp meta text in the card header.
enum MRCommentMetaStyle {
    static let metaColor = Color(nsColor: NSColor(srgbRed: 0x8E/255, green: 0x93/255, blue: 0x9C/255, alpha: 1))
}

// MARK: - Markdown rendering

/// MR descriptions and comments rendered with MarkdownUI under a compact
/// theme that matches the chrome of the surrounding cards. Supports the full
/// GitHub-flavored Markdown set (tables, task lists, strikethrough, nested
/// lists, autolinks, fenced code blocks).
struct MarkdownText: View {
    let source: String
    var baseFontSize: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Markdown(source.trimmingCharacters(in: .whitespacesAndNewlines))
            .markdownTheme(makeCommentTheme(baseFontSize: baseFontSize, isDark: colorScheme == .dark))
            .textSelection(.enabled)
    }
}

/// MarkdownUI theme for MR description and comment cards. Matches the
/// reference look: light gray sans-serif body, amber inline-code pills with
/// a dark-amber background, blue links without underline, hollow-circle
/// nested list bullets.
private func makeCommentTheme(baseFontSize: CGFloat, isDark: Bool) -> Theme {
    // Body palette (the cards live on a near-black surface, so colors are
    // tuned for dark mode and only soften in light mode).
    let textColor: Color = isDark
        ? Color(nsColor: NSColor(srgbRed: 0xD5/255, green: 0xD8/255, blue: 0xDD/255, alpha: 1))
        : .primary
    let headingColor: Color = isDark ? .white : .primary
    let secondaryTextColor: Color = isDark ? .white.opacity(0.55) : .secondary

    // Amber pill for inline code and code blocks.
    let codeFg = Color(nsColor: NSColor(srgbRed: 0xE5/255, green: 0xB8/255, blue: 0x64/255, alpha: 1))
    let inlineCodeBg = Color(nsColor: NSColor(srgbRed: 0x3B/255, green: 0x2E/255, blue: 0x1A/255, alpha: 1))
    let codeBlockBg = Color(nsColor: NSColor(srgbRed: 0x1A/255, green: 0x17/255, blue: 0x10/255, alpha: 1))

    // Blue link without underline (rendered as plain colored text).
    let linkColor = Color(nsColor: NSColor(srgbRed: 0x5B/255, green: 0xA0/255, blue: 0xF2/255, alpha: 1))

    let tableBorder: Color = isDark ? .white.opacity(0.15) : .gray.opacity(0.3)
    let tableRowA: Color = isDark
        ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
        : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    let tableRowB: Color = isDark
        ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
        : Color(nsColor: NSColor(white: 1.0, alpha: 1.0))
    let blockquoteBar: Color = isDark ? .white.opacity(0.22) : .gray.opacity(0.4)

    return Theme()
        .text {
            ForegroundColor(textColor)
            FontSize(baseFontSize)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(baseFontSize + 4)
                    ForegroundColor(headingColor)
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(baseFontSize + 2.5)
                    ForegroundColor(headingColor)
                }
                .markdownMargin(top: 10, bottom: 5)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(baseFontSize + 1.5)
                    ForegroundColor(headingColor)
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading4 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(baseFontSize + 0.5)
                    ForegroundColor(headingColor)
                }
                .markdownMargin(top: 6, bottom: 3)
        }
        .heading5 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(baseFontSize)
                    ForegroundColor(headingColor)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .heading6 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.medium)
                    FontSize(baseFontSize)
                    ForegroundColor(secondaryTextColor)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 4, bottom: 6)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        // Hollow circle bullets matching the reference look. MarkdownUI
        // already nests appropriately; the alternating preset would render
        // a filled disc on the outermost level, which is too heavy here.
        .bulletedListMarker(.circle)
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(baseFontSize - 1)
                        ForegroundColor(codeFg)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(codeBlockBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 6, bottom: 6)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(baseFontSize - 1.5)
            ForegroundColor(codeFg)
            BackgroundColor(inlineCodeBg)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(blockquoteBar)
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(secondaryTextColor)
                        FontSize(baseFontSize)
                    }
                    .padding(.leading, 12)
            }
            .markdownMargin(top: 6, bottom: 6)
        }
        .link {
            ForegroundColor(linkColor)
        }
        .strong {
            FontWeight(.semibold)
        }
        .strikethrough {
            StrikethroughStyle(.single)
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(color: tableBorder))
                .markdownTableBackgroundStyle(
                    .alternatingRows(tableRowA, tableRowB)
                )
                .markdownMargin(top: 6, bottom: 6)
        }
        .thematicBreak {
            Divider()
                .markdownMargin(top: 10, bottom: 10)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 14)

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
            RoundedRectangle(cornerRadius: 8)
                .fill(MRCommentCardStyle.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(MRCommentCardStyle.border, lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func noteRow(_ note: MRNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(initials(for: note))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(authorColor(for: note)))
                let displayName = note.authorName.isEmpty ? note.authorUsername : note.authorName
                Text(displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                if !note.authorUsername.isEmpty && note.authorUsername != note.authorName {
                    Text("@\(note.authorUsername)")
                        .font(.system(size: 13))
                        .foregroundStyle(MRCommentMetaStyle.metaColor)
                }
                if let when = note.createdAt {
                    Text("·")
                        .font(.system(size: 13))
                        .foregroundStyle(MRCommentMetaStyle.metaColor)
                    Text(relative(when))
                        .font(.system(size: 13))
                        .foregroundStyle(MRCommentMetaStyle.metaColor)
                }
                Spacer()
                if discussion.resolved {
                    Text("Resolved")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
            }
            MarkdownText(source: note.body, baseFontSize: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 38)  // align body with name (avatar 28 + spacing 10)
        }
        .padding(.vertical, 4)
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
