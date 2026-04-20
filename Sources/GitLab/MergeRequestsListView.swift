import SwiftUI

// MARK: - MR List State

@MainActor
final class MergeRequestsState: ObservableObject {
    @Published var mergeRequests: [GitLabMergeRequest] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastDirectory: String?

    private var fetchTask: Task<Void, Never>?
    private var requestCounter: UInt64 = 0

    func refresh(directory: String) {
        fetchTask?.cancel()
        requestCounter &+= 1
        let token = requestCounter

        if lastDirectory != directory {
            mergeRequests = []
        }
        lastDirectory = directory
        isLoading = true
        errorMessage = nil

        fetchTask = Task { [weak self] in
            let result: Result<[GitLabMergeRequest], Error>
            do {
                result = .success(try await fetchGitLabMergeRequests(in: directory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter, directory == self.lastDirectory else {
                return
            }

            switch result {
            case .success(let mrs):
                self.mergeRequests = mrs
                self.errorMessage = nil
            case .failure(let error):
                self.mergeRequests = []
                self.errorMessage = self.messageFor(error: error)
            }
            self.isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        requestCounter &+= 1
        mergeRequests = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
    }

    private func messageFor(error: Error) -> String {
        switch error {
        case GitLabMRFetchError.glabNotFound:
            return String(localized: "mr.error.glabNotFound", defaultValue: "glab not found")
        case GitLabMRFetchError.notGitLabRepo:
            return String(localized: "mr.error.notGitLab", defaultValue: "Not a GitLab repository")
        case GitLabMRFetchError.processError(let msg):
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - MR List View

struct MergeRequestsListView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var state = MergeRequestsState()
    @State private var reviewerFilter: String = ""  // empty = all

    var body: some View {
        VStack(spacing: 0) {
            mrHeader
            Divider()
            if !availableReviewers.isEmpty {
                reviewerFilterBar
                Divider()
            }
            if state.isLoading && state.mergeRequests.isEmpty {
                loadingState
            } else if let error = state.errorMessage, state.mergeRequests.isEmpty {
                errorState(error)
            } else if filteredMergeRequests.isEmpty {
                emptyState
            } else {
                mrList
            }
        }
        .onAppear { refreshIfNeeded() }
        .onChange(of: workspace.id) { _ in
            state.clear()
            refreshIfNeeded()
        }
        .onChange(of: workspace.currentDirectory) { _ in refreshIfNeeded() }
    }

    private var availableReviewers: [GitLabReviewer] {
        var seen = Set<String>()
        var result: [GitLabReviewer] = []
        for mr in state.mergeRequests {
            for r in mr.reviewers where !r.username.isEmpty {
                if seen.insert(r.username).inserted {
                    result.append(r)
                }
            }
        }
        return result.sorted { $0.username.lowercased() < $1.username.lowercased() }
    }

    private var filteredMergeRequests: [GitLabMergeRequest] {
        guard !reviewerFilter.isEmpty else { return state.mergeRequests }
        return state.mergeRequests.filter { mr in
            mr.reviewers.contains { $0.username == reviewerFilter }
        }
    }

    private var mrHeader: some View {
        HStack {
            if !state.mergeRequests.isEmpty {
                Text("\(filteredMergeRequests.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(.secondary.opacity(0.15))
                    )
            }
            Spacer()
            if state.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else {
                Button {
                    refreshIfNeeded()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var reviewerFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Menu {
                Button {
                    reviewerFilter = ""
                } label: {
                    HStack {
                        Text(String(localized: "mr.filter.allReviewers", defaultValue: "All reviewers"))
                        if reviewerFilter.isEmpty {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                ForEach(availableReviewers, id: \.username) { reviewer in
                    Button {
                        reviewerFilter = reviewer.username
                    } label: {
                        HStack {
                            Text(reviewer.name.isEmpty ? reviewer.username : "\(reviewer.name) (@\(reviewer.username))")
                            if reviewerFilter == reviewer.username {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentFilterLabel)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)

            if !reviewerFilter.isEmpty {
                Button {
                    reviewerFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "mr.filter.clear", defaultValue: "Clear filter"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var currentFilterLabel: String {
        if reviewerFilter.isEmpty {
            return String(localized: "mr.filter.allReviewers", defaultValue: "All reviewers")
        }
        if let match = availableReviewers.first(where: { $0.username == reviewerFilter }) {
            return match.name.isEmpty ? "@\(match.username)" : match.name
        }
        return "@\(reviewerFilter)"
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
            Text(String(localized: "mr.sidebar.loading", defaultValue: "Loading..."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button(String(localized: "mr.sidebar.retry", defaultValue: "Retry")) {
                refreshIfNeeded()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(
                reviewerFilter.isEmpty
                    ? String(localized: "mr.sidebar.empty", defaultValue: "No merge requests")
                    : String(localized: "mr.sidebar.emptyFiltered", defaultValue: "No merge requests match this filter")
            )
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mrList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredMergeRequests) { mr in
                    MRCardView(mr: mr, directory: workspace.currentDirectory)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func refreshIfNeeded() {
        let dir = workspace.currentDirectory
        guard !dir.isEmpty else { return }
        state.refresh(directory: dir)
    }
}

// MARK: - MR Card

private struct MRCardView: View {
    let mr: GitLabMergeRequest
    let directory: String
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            Text(mr.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !mr.labels.isEmpty {
                labelsView
            }

            Divider().opacity(0.5)

            metadataSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 1.0 : 0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            showDiff()
        }
        .contextMenu {
            Button {
                showDiff()
            } label: {
                Label(
                    String(localized: "mr.card.showDiff", defaultValue: "Show Diff"),
                    systemImage: "text.magnifyingglass"
                )
            }
            .disabled(directory.isEmpty || mr.sourceBranch.isEmpty || mr.targetBranch.isEmpty)
            Button {
                guard let url = URL(string: mr.webURL) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label(
                    String(localized: "mr.card.openBrowser", defaultValue: "Open in Browser"),
                    systemImage: "safari"
                )
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mr.webURL, forType: .string)
            } label: {
                Label(
                    String(localized: "mr.card.copyLink", defaultValue: "Copy Link"),
                    systemImage: "link"
                )
            }
        }
        .help(mr.webURL)
    }

    private func showDiff() {
        guard !directory.isEmpty,
              !mr.sourceBranch.isEmpty,
              !mr.targetBranch.isEmpty else {
            // Fallback when we can't compute a git diff (e.g. directory or
            // branches missing): open the MR in the browser.
            if let url = URL(string: mr.webURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let spec = GitDiffSpec(
            base: mr.targetBranch,
            compare: mr.sourceBranch,
            directory: directory,
            title: "!\(mr.iid) · \(mr.title)",
            mergeRequestIID: mr.iid,
            mergeRequestURL: mr.webURL
        )
        GitDiffWindowRegistry.show(spec: spec)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 6) {
            stateIcon
                .font(.system(size: 12, weight: .semibold))
            Text("!\(mr.iid)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if mr.userNotesCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(mr.userNotesCount)")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.15))
                )
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
                .help(String(
                    localized: "mr.card.comments",
                    defaultValue: "Comments"
                ))
            }
            if mr.isDraft {
                Text(String(localized: "mr.card.draft", defaultValue: "Draft"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.orange.opacity(0.15))
                    )
            }
            Spacer()
            if let created = mr.createdAt {
                Text(relativeTime(from: created))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(fullDate(created))
            }
        }
    }

    private func fullDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !mr.authorName.isEmpty || !mr.authorUsername.isEmpty {
                metaRow(
                    icon: "person.fill",
                    label: String(localized: "mr.card.author", defaultValue: "Author"),
                    content: AnyView(
                        AvatarLabel(
                            name: mr.authorName.isEmpty ? mr.authorUsername : mr.authorName,
                            username: mr.authorUsername
                        )
                    )
                )
            }

            if !mr.reviewers.isEmpty {
                metaRow(
                    icon: "person.2.fill",
                    label: String(localized: "mr.card.reviewers", defaultValue: "Reviewers"),
                    content: AnyView(reviewersView)
                )
            }
        }
    }

    @ViewBuilder
    private func metaRow(icon: String, label: String, content: AnyView) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 18, alignment: .center)
            content
        }
    }

    private var reviewersView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(mr.reviewers.prefix(4), id: \.username) { reviewer in
                HStack(spacing: 5) {
                    AvatarBadge(name: reviewer.name.isEmpty ? reviewer.username : reviewer.name)
                    Text(reviewer.name.isEmpty ? reviewer.username : reviewer.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !reviewer.username.isEmpty && reviewer.username != reviewer.name {
                        Text("@\(reviewer.username)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .help(reviewer.name.isEmpty ? "@\(reviewer.username)" : "\(reviewer.name) (@\(reviewer.username))")
            }
            if mr.reviewers.count > 4 {
                Text("+\(mr.reviewers.count - 4) \(String(localized: "mr.card.moreReviewers", defaultValue: "more"))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 23)
            }
        }
    }

    private var branchesView: some View {
        HStack(spacing: 4) {
            Text(mr.sourceBranch)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
            Text(mr.targetBranch)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch mr.state {
        case "opened":
            if mrHasMergeProblem {
                // Conflict / can't merge: warning triangle in orange.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(mergeProblemTooltip)
            } else {
                // Always-green arrow when opened without a known conflict.
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.green)
            }
        case "merged":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.purple)
        case "closed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var mrHasMergeProblem: Bool {
        if mr.hasConflicts { return true }
        return mr.mergeStatus == "cannot_be_merged"
            || mr.mergeStatus == "cannot_be_merged_recheck"
    }

    private var mergeProblemTooltip: String {
        if mr.hasConflicts {
            return String(localized: "mr.card.hasConflicts", defaultValue: "Has conflicts")
        }
        return String(localized: "mr.card.cannotBeMerged", defaultValue: "Cannot be merged")
    }

    @ViewBuilder
    private var labelsView: some View {
        let displayed = Array(mr.labels.prefix(4))
        HStack(spacing: 4) {
            ForEach(displayed, id: \.self) { label in
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.secondary.opacity(0.12))
                    )
                    .lineLimit(1)
            }
            if mr.labels.count > 4 {
                Text("+\(mr.labels.count - 4)")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Avatar components

struct AvatarBadge: View {
    let name: String

    private var initials: String {
        let parts = name.split(separator: " ")
        if let first = parts.first?.first, let second = parts.dropFirst().first?.first {
            return "\(first)\(second)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var color: Color {
        let hash = abs(name.hashValue)
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .cyan]
        return palette[hash % palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color.opacity(0.8)))
    }
}

struct AvatarLabel: View {
    let name: String
    let username: String

    var body: some View {
        HStack(spacing: 5) {
            AvatarBadge(name: name)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !username.isEmpty && username != name {
                Text("@\(username)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
