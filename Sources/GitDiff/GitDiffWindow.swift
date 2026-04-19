import SwiftUI
import AppKit

// MARK: - View Model

@MainActor
final class GitDiffViewModel: ObservableObject {
    @Published var spec: GitDiffSpec
    @Published var files: [GitDiffFile] = []
    @Published var selectedFile: GitDiffFile?
    @Published var currentDiff: String = ""
    @Published var isLoadingFiles = false
    @Published var isLoadingDiff = false
    @Published var filesError: String?
    @Published var diffError: String?

    private var fileListTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    init(spec: GitDiffSpec) {
        self.spec = spec
    }

    func reload() {
        loadFileList()
    }

    func updateSpec(_ newSpec: GitDiffSpec) {
        spec = newSpec
        selectedFile = nil
        currentDiff = ""
        files = []
        loadFileList()
    }

    private func loadFileList() {
        fileListTask?.cancel()
        isLoadingFiles = true
        filesError = nil

        fileListTask = Task { [weak self] in
            guard let self else { return }
            let spec = self.spec
            do {
                let result = try await fetchChangedFiles(spec: spec)
                guard !Task.isCancelled else { return }
                self.files = result
                self.isLoadingFiles = false
                if self.selectedFile == nil, let first = result.first {
                    self.select(first)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.files = []
                self.filesError = Self.message(for: error)
                self.isLoadingFiles = false
            }
        }
    }

    func select(_ file: GitDiffFile) {
        if selectedFile?.path == file.path { return }
        selectedFile = file
        loadDiff(for: file)
    }

    private func loadDiff(for file: GitDiffFile) {
        diffTask?.cancel()
        currentDiff = ""
        diffError = nil
        isLoadingDiff = true

        let spec = self.spec
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let diff = try await fetchUnifiedDiff(spec: spec, file: file.path)
                guard !Task.isCancelled, self.selectedFile?.path == file.path else { return }
                self.currentDiff = diff
                self.isLoadingDiff = false
            } catch {
                guard !Task.isCancelled, self.selectedFile?.path == file.path else { return }
                self.diffError = Self.message(for: error)
                self.currentDiff = ""
                self.isLoadingDiff = false
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let e = error as? GitDiffError {
            switch e {
            case .gitNotFound: return String(localized: "diff.error.gitNotFound", defaultValue: "git not found")
            case .notAGitRepo: return String(localized: "diff.error.notGit", defaultValue: "Not a git repository")
            case .processError(let m): return m.isEmpty ? "git error" : m
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Display Mode

enum GitDiffDisplayMode: String, CaseIterable {
    case sideBySide
    case unified
}

// MARK: - Main View

enum FileListMode: String {
    case tree
    case flat
}

struct GitDiffWindowView: View {
    @ObservedObject var viewModel: GitDiffViewModel
    @State private var displayMode: GitDiffDisplayMode = .sideBySide
    @State private var fileListMode: FileListMode = .tree
    @State private var prepared: SideBySidePrepared = .empty
    @State private var scrollHunkIndex: Int? = nil
    @State private var activeHunk: Int = 0
    @State private var collapsedFolders: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileListPane
                    .frame(minWidth: 60, idealWidth: 300, maxWidth: 300)
                diffPane
                    .frame(minWidth: 400, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear { rebuildPrepared() }
        .onChange(of: viewModel.currentDiff) { _ in rebuildPrepared() }
        .onChange(of: viewModel.selectedFile?.path) { _ in rebuildPrepared() }
        .background(HunkNavKeyMonitor(onPrev: goToPrevHunk, onNext: goToNextHunk))
    }

    private func rebuildPrepared() {
        prepared = SideBySidePrepared.from(
            diffText: viewModel.currentDiff,
            filePath: viewModel.selectedFile?.path
        )
        activeHunk = 0
    }

    private var hunkCount: Int { prepared.leftHunkOffsets.count }

    private func goToPrevHunk() {
        guard hunkCount > 0 else { return }
        activeHunk = max(0, activeHunk - 1)
        scrollHunkIndex = activeHunk
    }

    private func goToNextHunk() {
        guard hunkCount > 0 else { return }
        activeHunk = min(hunkCount - 1, activeHunk + 1)
        scrollHunkIndex = activeHunk
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(viewModel.spec.title)
                .font(.headline)
            Text(rangeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.secondary.opacity(0.12)))
            Spacer()
            if viewModel.isLoadingFiles {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
            }
            HStack(spacing: 2) {
                Button {
                    goToPrevHunk()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(hunkCount == 0)
                .help(String(localized: "diff.prevHunk", defaultValue: "Previous change (Shift+F7)"))
                Button {
                    goToNextHunk()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(hunkCount == 0)
                .help(String(localized: "diff.nextHunk", defaultValue: "Next change (F7)"))
                if hunkCount > 0 {
                    Text("\(min(activeHunk + 1, hunkCount))/\(hunkCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $displayMode) {
                Image(systemName: "rectangle.split.2x1").tag(GitDiffDisplayMode.sideBySide)
                    .help(String(localized: "diff.sideBySide", defaultValue: "Side by side"))
                Image(systemName: "list.bullet.indent").tag(GitDiffDisplayMode.unified)
                    .help(String(localized: "diff.unified", defaultValue: "Unified"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "diff.reload", defaultValue: "Reload"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var rangeLabel: String {
        if let compare = viewModel.spec.compare {
            return "\(viewModel.spec.base) ← \(compare)"
        }
        return "\(viewModel.spec.base) ← working tree"
    }

    @ViewBuilder
    private var fileListPane: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            if viewModel.isLoadingFiles && viewModel.files.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let err = viewModel.filesError, viewModel.files.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.files.isEmpty {
                VStack {
                    Spacer()
                    Text(String(localized: "diff.noChanges", defaultValue: "No changes"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                switch fileListMode {
                case .flat:
                    flatFileList
                case .tree:
                    treeFileList
                }
            }
        }
    }

    private var flatFileList: some View {
        List(selection: selectionBinding) {
            ForEach(viewModel.files) { file in
                GitDiffFileRow(file: file)
                    .tag(file.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.select(file)
                    }
            }
        }
        .listStyle(.sidebar)
    }

    private var treeFileList: some View {
        let root = FileTreeBuilder.build(from: viewModel.files)
        return List(selection: selectionBinding) {
            ForEach(flattenVisible(root, depth: 0), id: \.node.id) { entry in
                if let file = entry.node.file {
                    GitDiffFileRow(file: file, depth: entry.depth)
                        .tag(file.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.select(file)
                        }
                } else {
                    GitDiffFolderRow(
                        node: entry.node,
                        depth: entry.depth,
                        isExpanded: !collapsedFolders.contains(entry.node.id)
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleFolder(entry.node.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func flattenVisible(
        _ nodes: [FileTreeNode],
        depth: Int
    ) -> [(node: FileTreeNode, depth: Int)] {
        var result: [(FileTreeNode, Int)] = []
        for node in nodes {
            result.append((node, depth))
            if let children = node.children, !collapsedFolders.contains(node.id) {
                result.append(contentsOf: flattenVisible(children, depth: depth + 1))
            }
        }
        return result
    }

    private func toggleFolder(_ id: String) {
        if collapsedFolders.contains(id) {
            collapsedFolders.remove(id)
        } else {
            collapsedFolders.insert(id)
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedFile?.id },
            set: { newId in
                if let id = newId, let f = viewModel.files.first(where: { $0.id == id }) {
                    viewModel.select(f)
                }
            }
        )
    }

    private var summaryBar: some View {
        let totalAdds = viewModel.files.reduce(0) { $0 + $1.additions }
        let totalDels = viewModel.files.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 10) {
            Text("\(viewModel.files.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("+\(totalAdds)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
            Text("-\(totalDels)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
            Spacer()
            Picker("", selection: $fileListMode) {
                Image(systemName: "list.bullet.indent").tag(FileListMode.tree)
                    .help(String(localized: "diff.fileList.tree", defaultValue: "Tree view"))
                Image(systemName: "list.bullet").tag(FileListMode.flat)
                    .help(String(localized: "diff.fileList.flat", defaultValue: "Flat view"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 74)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var diffPane: some View {
        if let file = viewModel.selectedFile {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(file.path)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if viewModel.isLoadingDiff {
                        ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                if let err = viewModel.diffError {
                    VStack {
                        Spacer()
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.currentDiff.isEmpty && !viewModel.isLoadingDiff {
                    VStack {
                        Spacer()
                        Text(String(localized: "diff.binaryOrEmpty", defaultValue: "Binary or empty diff"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch displayMode {
                    case .sideBySide:
                        SideBySideDiffView(
                            prepared: prepared,
                            scrollHunkIndex: $scrollHunkIndex
                        )
                    case .unified:
                        UnifiedDiffTextView(
                            text: viewModel.currentDiff,
                            filePath: viewModel.selectedFile?.path
                        )
                    }
                }
            }
        } else {
            VStack {
                Spacer()
                Text(String(localized: "diff.selectFile", defaultValue: "Select a file to view its diff"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - File Row

private enum DiffTreeMetrics {
    static let indentWidth: CGFloat = 5
    static let chevronWidth: CGFloat = 11
    static let rowVerticalPadding: CGFloat = 1
}

private struct DiffTreeIndentGuides: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1)
                }
                .frame(width: DiffTreeMetrics.indentWidth)
            }
        }
    }
}

private struct GitDiffFileRow: View {
    let file: GitDiffFile
    var depth: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            DiffTreeIndentGuides(depth: depth)
            HStack(spacing: 4) {
                // Empty slot where a sibling folder's chevron would sit, so
                // file names stay aligned with folders above.
                Spacer().frame(width: DiffTreeMetrics.chevronWidth)
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if depth == 0 {
                    let parent = (file.path as NSString).deletingLastPathComponent
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if file.isBinary {
                    Text("BIN")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 2) {
                        if file.additions > 0 {
                            Text("+\(file.additions)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if file.deletions > 0 {
                            Text("-\(file.deletions)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(.vertical, DiffTreeMetrics.rowVerticalPadding)
        }
        .help(file.path)
    }

    /// VS Code `gitDecoration.*ResourceForeground` palette — soft, easy on the eyes.
    private var statusColor: Color {
        switch file.changeType {
        case .added:
            // #81B88B
            return Color(nsColor: NSColor(srgbRed: 0x81/255, green: 0xB8/255, blue: 0x8B/255, alpha: 1))
        case .modified:
            // #E2C08D — VS Code uses amber, not blue, for modified files.
            return Color(nsColor: NSColor(srgbRed: 0xE2/255, green: 0xC0/255, blue: 0x8D/255, alpha: 1))
        case .deleted:
            // #C74E39
            return Color(nsColor: NSColor(srgbRed: 0xC7/255, green: 0x4E/255, blue: 0x39/255, alpha: 1))
        case .renamed, .copied:
            // #73C991
            return Color(nsColor: NSColor(srgbRed: 0x73/255, green: 0xC9/255, blue: 0x91/255, alpha: 1))
        default:
            return Color(nsColor: .labelColor).opacity(0.85)
        }
    }
}

// MARK: - File tree

struct FileTreeNode: Identifiable, Equatable {
    let id: String            // full path segments joined, or file path
    let displayName: String   // folder name or filename
    let file: GitDiffFile?    // nil → folder
    var additions: Int
    var deletions: Int
    var fileCount: Int
    var children: [FileTreeNode]?
}

enum FileTreeBuilder {
    static func build(from files: [GitDiffFile]) -> [FileTreeNode] {
        var roots: [FileTreeNode] = []
        for file in files {
            insert(file: file, into: &roots, pathPrefix: "")
        }
        sortInPlace(&roots)
        aggregateStats(&roots)
        // Collapse single-child folder chains like `src/components/ui` into one row,
        // matching VS Code's "compact folders" default.
        for i in roots.indices {
            roots[i] = compact(roots[i])
        }
        return roots
    }

    private static func insert(file: GitDiffFile, into nodes: inout [FileTreeNode], pathPrefix: String) {
        let fullPath = file.path
        let components = fullPath.split(separator: "/").map(String.init)
        insertInto(&nodes, components: components, file: file, pathPrefix: pathPrefix)
    }

    private static func insertInto(
        _ nodes: inout [FileTreeNode],
        components: [String],
        file: GitDiffFile,
        pathPrefix: String
    ) {
        guard let first = components.first else { return }
        let newPrefix = pathPrefix.isEmpty ? first : pathPrefix + "/" + first
        if components.count == 1 {
            nodes.append(FileTreeNode(
                id: newPrefix,
                displayName: first,
                file: file,
                additions: file.additions,
                deletions: file.deletions,
                fileCount: 1,
                children: nil
            ))
            return
        }
        let rest = Array(components.dropFirst())
        if let idx = nodes.firstIndex(where: { $0.file == nil && $0.displayName == first }) {
            var folder = nodes[idx]
            var children = folder.children ?? []
            insertInto(&children, components: rest, file: file, pathPrefix: newPrefix)
            folder.children = children
            nodes[idx] = folder
        } else {
            var children: [FileTreeNode] = []
            insertInto(&children, components: rest, file: file, pathPrefix: newPrefix)
            nodes.append(FileTreeNode(
                id: "folder:" + newPrefix,
                displayName: first,
                file: nil,
                additions: 0,
                deletions: 0,
                fileCount: 0,
                children: children
            ))
        }
    }

    private static func sortInPlace(_ nodes: inout [FileTreeNode]) {
        nodes.sort { lhs, rhs in
            let lIsFolder = lhs.file == nil
            let rIsFolder = rhs.file == nil
            if lIsFolder != rIsFolder { return lIsFolder && !rIsFolder }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        for i in nodes.indices {
            if var children = nodes[i].children {
                sortInPlace(&children)
                nodes[i].children = children
            }
        }
    }

    @discardableResult
    private static func aggregateStats(_ nodes: inout [FileTreeNode]) -> (adds: Int, dels: Int, count: Int) {
        var totalAdds = 0
        var totalDels = 0
        var totalCount = 0
        for i in nodes.indices {
            if var children = nodes[i].children {
                let child = aggregateStats(&children)
                nodes[i].children = children
                nodes[i].additions = child.adds
                nodes[i].deletions = child.dels
                nodes[i].fileCount = child.count
                totalAdds += child.adds
                totalDels += child.dels
                totalCount += child.count
            } else {
                totalAdds += nodes[i].additions
                totalDels += nodes[i].deletions
                totalCount += 1
            }
        }
        return (totalAdds, totalDels, totalCount)
    }

    /// Collapse chains like foo → bar → baz where each has exactly one folder child
    /// into a single node named "foo/bar/baz". Stops when the descendant is a file or
    /// has more than one child.
    private static func compact(_ node: FileTreeNode) -> FileTreeNode {
        var node = node
        if var children = node.children {
            for i in children.indices {
                children[i] = compact(children[i])
            }
            node.children = children
            if node.file == nil, children.count == 1, children[0].file == nil {
                let only = children[0]
                return FileTreeNode(
                    id: node.id,
                    displayName: node.displayName + "/" + only.displayName,
                    file: nil,
                    additions: only.additions,
                    deletions: only.deletions,
                    fileCount: only.fileCount,
                    children: only.children
                )
            }
        }
        return node
    }
}

private struct GitDiffFolderRow: View {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            DiffTreeIndentGuides(depth: depth)
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: DiffTreeMetrics.chevronWidth)
                Text(node.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    if node.additions > 0 {
                        Text("+\(node.additions)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.75))
                    }
                    if node.deletions > 0 {
                        Text("-\(node.deletions)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.75))
                    }
                }
            }
            .padding(.vertical, DiffTreeMetrics.rowVerticalPadding)
        }
    }
}

// MARK: - Unified Diff Text View (NSTextView-backed for perf)

struct UnifiedDiffTextView: NSViewRepresentable {
    let text: String
    let filePath: String?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        update(textView: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        update(textView: textView)
    }

    private func update(textView: NSTextView) {
        let attributed = Self.attributedDiff(from: text, filePath: filePath)
        textView.textStorage?.setAttributedString(attributed)
    }

    static func attributedDiff(from text: String, filePath: String?) -> NSAttributedString {
        let font = codeFont()
        let language = filePath.map { HighlightLanguage.detect(fromFilePath: $0) } ?? .plaintext

        // Build: keep track of per-line ranges and their kind so we can apply
        // row backgrounds and also run syntax highlighting only on the content
        // portion (skipping the leading marker character).
        let result = NSMutableAttributedString()
        // For syntax highlighting we maintain a parallel "pure content" string
        // and the mapping from its indices back into `result`.
        let pureContent = NSMutableString()
        var segments: [(contentRange: NSRange, resultRange: NSRange)] = []

        var lineRanges: [(NSRange, NSColor?)] = []

        text.enumerateLines { line, _ in
            let fg: NSColor
            let bg: NSColor?
            let hasContent: Bool
            let contentStartOffset: Int
            if line.hasPrefix("+++") || line.hasPrefix("---")
                || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
                || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
                || line.hasPrefix("Binary ") {
                fg = .secondaryLabelColor
                bg = nil
                hasContent = false
                contentStartOffset = 0
            } else if line.hasPrefix("@@") {
                fg = .systemBlue
                bg = NSColor.systemBlue.withAlphaComponent(0.1)
                hasContent = false
                contentStartOffset = 0
            } else if line.hasPrefix("+") {
                fg = .labelColor
                bg = NSColor.systemGreen.withAlphaComponent(0.16)
                hasContent = true
                contentStartOffset = 1
            } else if line.hasPrefix("-") {
                fg = .labelColor
                bg = NSColor.systemRed.withAlphaComponent(0.16)
                hasContent = true
                contentStartOffset = 1
            } else {
                fg = .labelColor
                bg = nil
                hasContent = true
                contentStartOffset = line.isEmpty ? 0 : 1
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fg,
            ]
            if let bg { attrs[.backgroundColor] = bg }
            let rendered = line + "\n"
            let resultStart = result.length
            result.append(NSAttributedString(string: rendered, attributes: attrs))
            let resultRange = NSRange(location: resultStart, length: rendered.utf16.count)
            lineRanges.append((resultRange, bg))
            if hasContent {
                let trimmedStart = resultStart + contentStartOffset
                let contentUTF16 = (line as NSString).length - contentStartOffset
                if contentUTF16 > 0 {
                    let contentStart = pureContent.length
                    let contentStr = (line as NSString).substring(from: contentStartOffset)
                    pureContent.append(contentStr + "\n")
                    segments.append((
                        contentRange: NSRange(location: contentStart, length: contentUTF16 + 1),
                        resultRange: NSRange(location: trimmedStart, length: contentUTF16 + 1)
                    ))
                } else {
                    pureContent.append("\n")
                }
            } else {
                pureContent.append("\n")
            }
        }

        // Syntax highlight the reconstructed "code" side, then copy the
        // foreground attributes back onto the visible result at the mapped
        // ranges. This keeps markers and headers in their neutral color.
        let contentAttr = NSMutableAttributedString(
            string: pureContent as String,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        SyntaxHighlighter.apply(to: contentAttr, language: language)
        for seg in segments {
            contentAttr.enumerateAttribute(
                .foregroundColor,
                in: seg.contentRange,
                options: []
            ) { value, subRange, _ in
                guard let color = value as? NSColor else { return }
                let offsetInSeg = subRange.location - seg.contentRange.location
                let targetLoc = seg.resultRange.location + offsetInSeg
                let targetRange = NSRange(location: targetLoc, length: subRange.length)
                if targetRange.location + targetRange.length <= result.length {
                    result.addAttribute(.foregroundColor, value: color, range: targetRange)
                }
            }
        }
        return result
    }
}

// MARK: - Side-by-side Diff View

/// Pre-built data for side-by-side rendering. Computing attributed strings
/// every body pass would be slow for large diffs; the window view caches this
/// value in `@State` and only rebuilds when the diff text changes.
struct DiffRowBackground {
    let range: NSRange
    let color: NSColor
}

struct SideBySidePrepared: Equatable {
    var leftAttr: NSAttributedString
    var rightAttr: NSAttributedString
    var leftHunkOffsets: [Int]
    var rightHunkOffsets: [Int]
    var leftLineKinds: [SideBySideLineKind]
    var rightLineKinds: [SideBySideLineKind]
    var leftRowBackgrounds: [DiffRowBackground]
    var rightRowBackgrounds: [DiffRowBackground]
    /// Line numbers for the line number gutter (nil = no number shown).
    var leftLineNumbers: [Int?]
    var rightLineNumbers: [Int?]
    /// UTF-16 character indices at the start of each line, parallel to
    /// `*LineNumbers`. Used by the gutter ruler to map glyph → line index.
    var leftLineStarts: [Int]
    var rightLineStarts: [Int]

    static let empty = SideBySidePrepared(
        leftAttr: NSAttributedString(),
        rightAttr: NSAttributedString(),
        leftHunkOffsets: [],
        rightHunkOffsets: [],
        leftLineKinds: [],
        rightLineKinds: [],
        leftRowBackgrounds: [],
        rightRowBackgrounds: [],
        leftLineNumbers: [],
        rightLineNumbers: [],
        leftLineStarts: [],
        rightLineStarts: []
    )

    static func == (lhs: SideBySidePrepared, rhs: SideBySidePrepared) -> Bool {
        lhs.leftAttr.isEqual(to: rhs.leftAttr)
            && rhs.rightAttr.isEqual(to: lhs.rightAttr)
            && lhs.leftHunkOffsets == rhs.leftHunkOffsets
            && lhs.rightHunkOffsets == rhs.rightHunkOffsets
            && lhs.leftLineKinds == rhs.leftLineKinds
            && lhs.rightLineKinds == rhs.rightLineKinds
            && lhs.leftLineNumbers == rhs.leftLineNumbers
            && lhs.rightLineNumbers == rhs.rightLineNumbers
    }

    static func from(diffText: String, filePath: String?) -> SideBySidePrepared {
        let rows = parseSideBySideRows(from: diffText)
        if rows.isEmpty { return .empty }
        let font = codeFont()
        // Force min/max line height equal to the font's natural line height so
        // background colors fill the row continuously (setting only
        // lineHeightMultiple leaves a gap between consecutive highlighted lines).
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let language = filePath.map { HighlightLanguage.detect(fromFilePath: $0) } ?? .plaintext

        // Compute gutter width from the max line number seen in any row.
        let left = NSMutableAttributedString()
        let right = NSMutableAttributedString()
        var leftHunks: [Int] = []
        var rightHunks: [Int] = []
        var leftLineKinds: [SideBySideLineKind] = []
        var rightLineKinds: [SideBySideLineKind] = []
        var leftLineNumbers: [Int?] = []
        var rightLineNumbers: [Int?] = []
        var leftLineStarts: [Int] = []
        var rightLineStarts: [Int] = []
        var leftContentRanges: [NSRange] = []
        var rightContentRanges: [NSRange] = []
        var leftRowBackgrounds: [(NSRange, NSColor)] = []
        var rightRowBackgrounds: [(NSRange, NSColor)] = []
        var leftIntraRanges: [(NSRange, NSColor)] = []
        var rightIntraRanges: [(NSRange, NSColor)] = []

        func appendLine(
            into attr: NSMutableAttributedString,
            cell: SideBySideCell,
            kinds: inout [SideBySideLineKind],
            lineNumbers: inout [Int?],
            lineStarts: inout [Int],
            contentRanges: inout [NSRange],
            rowBackgrounds: inout [(NSRange, NSColor)],
            intraRanges: inout [(NSRange, NSColor)]
        ) {
            let start = attr.length
            lineStarts.append(start)
            let content = cell.kind == .empty ? "" : cell.content
            let rendered = content + "\n"
            attr.append(NSAttributedString(
                string: rendered,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            let contentUTF16Len = (content as NSString).length
            let renderedUTF16Len = (rendered as NSString).length
            // Row background for the whole line.
            if let rowBg = rowBackgroundColor(for: cell.kind) {
                let range = NSRange(location: start, length: renderedUTF16Len)
                rowBackgrounds.append((range, rowBg))
            }
            if cell.kind == .empty {
                let range = NSRange(location: start, length: renderedUTF16Len)
                rowBackgrounds.append((range, Self.diagonalHatchColor))
            }
            // Content range for syntax highlighting.
            if cell.kind != .empty, contentUTF16Len > 0 {
                contentRanges.append(NSRange(location: start, length: contentUTF16Len))
            }
            if !cell.intraLineRanges.isEmpty, let stronger = intraLineColor(for: cell.kind) {
                for r in cell.intraLineRanges {
                    let adjusted = NSRange(location: start + r.location, length: r.length)
                    intraRanges.append((adjusted, stronger))
                }
            }
            kinds.append(cell.kind)
            lineNumbers.append(cell.kind == .empty ? nil : cell.lineNumber)
        }

        for row in rows {
            switch row {
            case .hunkHeader:
                // Hunk headers (`@@ -N,M +A,B @@ context`) are not rendered:
                // VS Code only shows the line-number jump on either side. We
                // still record the insertion point for F7 navigation.
                leftHunks.append(left.length)
                rightHunks.append(right.length)
            case .pair(_, let l, let r):
                appendLine(
                    into: left,
                    cell: l,
                    kinds: &leftLineKinds,
                    lineNumbers: &leftLineNumbers,
                    lineStarts: &leftLineStarts,
                    contentRanges: &leftContentRanges,
                    rowBackgrounds: &leftRowBackgrounds,
                    intraRanges: &leftIntraRanges
                )
                appendLine(
                    into: right,
                    cell: r,
                    kinds: &rightLineKinds,
                    lineNumbers: &rightLineNumbers,
                    lineStarts: &rightLineStarts,
                    contentRanges: &rightContentRanges,
                    rowBackgrounds: &rightRowBackgrounds,
                    intraRanges: &rightIntraRanges
                )
            }
        }

        // Syntax highlighting: extract pure code substring per side, highlight,
        // copy foreground colors back.
        applySyntax(
            to: left,
            contentRanges: leftContentRanges,
            language: language,
            font: font
        )
        applySyntax(
            to: right,
            contentRanges: rightContentRanges,
            language: language,
            font: font
        )

        // Only intra-line stronger ranges are baked into the attributed
        // string. Row backgrounds are returned separately so the text view
        // can fill the full editor width underneath the glyphs.
        for (range, color) in leftIntraRanges {
            left.addAttribute(.backgroundColor, value: color, range: range)
        }
        for (range, color) in rightIntraRanges {
            right.addAttribute(.backgroundColor, value: color, range: range)
        }

        return SideBySidePrepared(
            leftAttr: left,
            rightAttr: right,
            leftHunkOffsets: leftHunks,
            rightHunkOffsets: rightHunks,
            leftLineKinds: leftLineKinds,
            rightLineKinds: rightLineKinds,
            leftRowBackgrounds: leftRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            rightRowBackgrounds: rightRowBackgrounds.map { DiffRowBackground(range: $0.0, color: $0.1) },
            leftLineNumbers: leftLineNumbers,
            rightLineNumbers: rightLineNumbers,
            leftLineStarts: leftLineStarts,
            rightLineStarts: rightLineStarts
        )
    }

    // MARK: Color palette (VS Code Dark+ / default dark)

    private static let hunkForeground = NSColor(srgbRed: 86/255, green: 156/255, blue: 214/255, alpha: 1)
    private static let hunkBackground = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.0)  // subtle; real tint comes from row color
    private static let diagonalHatchColor: NSColor = DiffHatchPattern.color()

    private static func formatLineNumber(_ n: Int?, width: Int) -> String {
        guard let n else { return String(repeating: " ", count: width) }
        let s = String(n)
        if s.count >= width { return s }
        return String(repeating: " ", count: width - s.count) + s
    }

    // Solid colors (pre-composited against the VS Code editor background
    // `#1E1E1E`) so they land exactly like VS Code no matter what
    // macOS decides for `.textBackgroundColor`.
    private static func rowBackgroundColor(for kind: SideBySideLineKind) -> NSColor? {
        switch kind {
        case .added: return NSColor(srgbRed: 0x37/255, green: 0x3D/255, blue: 0x29/255, alpha: 1)
        case .deleted: return NSColor(srgbRed: 0x4B/255, green: 0x18/255, blue: 0x18/255, alpha: 1)
        case .hunk: return NSColor(srgbRed: 0x23/255, green: 0x2D/255, blue: 0x3C/255, alpha: 1)
        case .context, .empty: return nil
        }
    }

    private static func intraLineColor(for kind: SideBySideLineKind) -> NSColor? {
        switch kind {
        case .added: return NSColor(srgbRed: 0x55/255, green: 0x62/255, blue: 0x2E/255, alpha: 1)
        case .deleted: return NSColor(srgbRed: 0x6F/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1)
        case .context, .empty, .hunk: return nil
        }
    }

    private static func applySyntax(
        to attr: NSMutableAttributedString,
        contentRanges: [NSRange],
        language: HighlightLanguage,
        font: NSFont
    ) {
        guard language != .plaintext, !contentRanges.isEmpty else { return }

        // Build a synthetic code buffer that concatenates the content of each
        // tracked range (plus a separator newline) so multi-line constructs
        // like block comments survive across rows.
        let synthetic = NSMutableString()
        var mapping: [(synRange: NSRange, resultRange: NSRange)] = []
        for cr in contentRanges {
            let piece = (attr.string as NSString).substring(with: cr)
            let synStart = synthetic.length
            synthetic.append(piece)
            synthetic.append("\n")
            mapping.append((
                synRange: NSRange(location: synStart, length: cr.length),
                resultRange: cr
            ))
        }
        let synAttr = NSMutableAttributedString(
            string: synthetic as String,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        SyntaxHighlighter.apply(to: synAttr, language: language)

        for map in mapping {
            synAttr.enumerateAttribute(
                .foregroundColor,
                in: map.synRange,
                options: []
            ) { value, subRange, _ in
                guard let color = value as? NSColor else { return }
                let offsetInSeg = subRange.location - map.synRange.location
                let targetLoc = map.resultRange.location + offsetInSeg
                let targetRange = NSRange(location: targetLoc, length: subRange.length)
                if targetRange.location + targetRange.length <= attr.length {
                    attr.addAttribute(.foregroundColor, value: color, range: targetRange)
                }
            }
        }
    }
}

struct SideBySideDiffView: View {
    let prepared: SideBySidePrepared
    @Binding var scrollHunkIndex: Int?

    var body: some View {
        DiffCodeTextView(
            left: prepared.leftAttr,
            right: prepared.rightAttr,
            leftHunkOffsets: prepared.leftHunkOffsets,
            rightHunkOffsets: prepared.rightHunkOffsets,
            leftLineKinds: prepared.leftLineKinds,
            rightLineKinds: prepared.rightLineKinds,
            leftRowBackgrounds: prepared.leftRowBackgrounds,
            rightRowBackgrounds: prepared.rightRowBackgrounds,
            leftLineNumbers: prepared.leftLineNumbers,
            rightLineNumbers: prepared.rightLineNumbers,
            leftLineStarts: prepared.leftLineStarts,
            rightLineStarts: prepared.rightLineStarts,
            scrollHunkIndex: $scrollHunkIndex
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Keyboard Handler

/// Transparent helper view that installs a local NSEvent monitor scoped to
/// the hosting window, to pick up F7 / Shift+F7 even when focus is inside
/// the NSTextView. Using `.onKeyPress` does not fire for F-keys reliably.
struct HunkNavKeyMonitor: NSViewRepresentable {
    let onPrev: () -> Void
    let onNext: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyMonitorView()
        view.onPrev = onPrev
        view.onNext = onNext
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyMonitorView else { return }
        view.onPrev = onPrev
        view.onNext = onNext
    }

    private final class KeyMonitorView: NSView {
        var onPrev: (() -> Void)?
        var onNext: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let existing = monitor {
                NSEvent.removeMonitor(existing)
                monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.window === self.window else { return event }
                // F7 has keyCode 98. Shift+F7 combines with shift mask.
                if event.keyCode == 98 {
                    if event.modifierFlags.contains(.shift) {
                        self.onPrev?()
                    } else {
                        self.onNext?()
                    }
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Window Controller

@MainActor
final class GitDiffWindowController: NSWindowController {
    private let viewModel: GitDiffViewModel

    init(spec: GitDiffSpec) {
        self.viewModel = GitDiffViewModel(spec: spec)
        let hosting = NSHostingController(rootView: GitDiffWindowView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hosting)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.setFrame(screen, display: true)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.title = spec.title
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show() {
        viewModel.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Registry to avoid duplicates

@MainActor
enum GitDiffWindowRegistry {
    private static var openControllers: [String: GitDiffWindowController] = [:]

    static func show(spec: GitDiffSpec) {
        let key = "\(spec.directory)|\(spec.base)|\(spec.compare ?? "<worktree>")"
        if let existing = openControllers[key] {
            existing.show()
            return
        }
        let controller = GitDiffWindowController(spec: spec)
        openControllers[key] = controller
        controller.window?.delegate = GitDiffWindowRegistryDelegate.shared
        GitDiffWindowRegistryDelegate.shared.register(key: key, window: controller.window)
        controller.show()
    }

    fileprivate static func remove(key: String) {
        openControllers[key] = nil
    }
}

@MainActor
private final class GitDiffWindowRegistryDelegate: NSObject, NSWindowDelegate {
    static let shared = GitDiffWindowRegistryDelegate()

    private var keyByWindow: [ObjectIdentifier: String] = [:]

    func register(key: String, window: NSWindow?) {
        guard let window else { return }
        keyByWindow[ObjectIdentifier(window)] = key
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)
        if let key = keyByWindow.removeValue(forKey: id) {
            GitDiffWindowRegistry.remove(key: key)
        }
    }
}

// MARK: - Code font helper

/// Mirrors VS Code's macOS default stack: `Menlo, Monaco, 'Courier New'`.
func codeFont(size: CGFloat = 12) -> NSFont {
    for name in ["Menlo", "Monaco", "Courier New"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

// MARK: - Diagonal hatch pattern (for empty-side padding rows)

enum DiffHatchPattern {
    /// Returns a pattern NSColor that renders diagonal stripes similar to
    /// VS Code's "empty side" marker on side-by-side diffs. Produces a
    /// dark tile with clearly-visible light diagonal stripes.
    static func color() -> NSColor {
        if let cached { return cached }
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        // Opaque slightly-darker-than-editor background so the hatch tile
        // reads as "no line here" rather than transparent.
        NSColor(srgbRed: 0x1A/255, green: 0x1A/255, blue: 0x1A/255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let stripe = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
        stripe.setStroke()
        // Two diagonals to ensure a continuous pattern when tiled.
        for offset in stride(from: -size, through: size, by: size) {
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.move(to: NSPoint(x: offset, y: 0))
            path.line(to: NSPoint(x: offset + size, y: size))
            path.stroke()
        }
        image.unlockFocus()
        let color = NSColor(patternImage: image)
        cached = color
        return color
    }

    nonisolated(unsafe) private static var cached: NSColor?
}
