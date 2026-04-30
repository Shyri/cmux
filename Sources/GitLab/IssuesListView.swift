import SwiftUI
import AppKit

// MARK: - Issues State

@MainActor
final class IssuesState: ObservableObject {
    @Published var issues: [GitLabIssue] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastDirectory: String?
    @Published private(set) var projectWebURL: String?

    private var fetchTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var requestCounter: UInt64 = 0

    func refresh(directory: String) {
        fetchTask?.cancel()
        remoteTask?.cancel()
        requestCounter &+= 1
        let token = requestCounter

        if lastDirectory != directory {
            issues = []
            projectWebURL = nil
        }
        lastDirectory = directory
        isLoading = true
        errorMessage = nil

        remoteTask = Task { [weak self] in
            let url = await gitLabProjectWebURL(directory: directory)
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter,
                  directory == self.lastDirectory else { return }
            self.projectWebURL = url
        }

        fetchTask = Task { [weak self] in
            let result: Result<[GitLabIssue], Error>
            do {
                result = .success(try await fetchGitLabIssues(in: directory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter, directory == self.lastDirectory else {
                return
            }

            switch result {
            case .success(let items):
                self.issues = items
                self.errorMessage = nil
            case .failure(let error):
                self.issues = []
                self.errorMessage = self.messageFor(error: error)
            }
            self.isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        remoteTask?.cancel()
        requestCounter &+= 1
        issues = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
        projectWebURL = nil
    }

    private func messageFor(error: Error) -> String {
        switch error {
        case GitLabIssueFetchError.glabNotFound:
            return String(localized: "issue.error.glabNotFound", defaultValue: "glab not found")
        case GitLabIssueFetchError.notGitLabRepo:
            return String(localized: "issue.error.notGitLab", defaultValue: "Not a GitLab repository")
        case GitLabIssueFetchError.processError(let msg):
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Issues List View

private let kNoMilestoneSentinel = "__none__"

struct IssuesListView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var state = IssuesState()
    @State private var milestoneFilter: String = ""  // "" = all, kNoMilestoneSentinel = no milestone, else milestone title

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !availableMilestones.isEmpty || state.issues.contains(where: { $0.milestone == nil }) {
                milestoneFilterBar
                Divider()
            }
            if state.isLoading && state.issues.isEmpty {
                loadingState
            } else if let error = state.errorMessage, state.issues.isEmpty {
                errorState(error)
            } else if filteredIssues.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear { refreshIfNeeded() }
        .onChange(of: workspace.currentDirectory) { _ in
            milestoneFilter = ""
            refreshIfNeeded()
        }
    }

    private var availableMilestones: [GitLabMilestone] {
        var seen = Set<String>()
        var result: [GitLabMilestone] = []
        for issue in state.issues {
            guard let m = issue.milestone, !m.title.isEmpty else { continue }
            if seen.insert(m.title).inserted {
                result.append(m)
            }
        }
        return result.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title.lowercased() < rhs.title.lowercased()
            }
        }
    }

    private var filteredIssues: [GitLabIssue] {
        if milestoneFilter.isEmpty { return state.issues }
        if milestoneFilter == kNoMilestoneSentinel {
            return state.issues.filter { $0.milestone == nil }
        }
        return state.issues.filter { $0.milestone?.title == milestoneFilter }
    }

    private var header: some View {
        HStack {
            if !state.issues.isEmpty {
                Text("\(filteredIssues.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
            if let boardsURL = issueBoardURL {
                Button {
                    NSWorkspace.shared.open(boardsURL)
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(
                    localized: "issue.sidebar.openBoard",
                    defaultValue: "Open issue board"
                ))
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

    private var milestoneFilterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Menu {
                Button {
                    milestoneFilter = ""
                } label: {
                    HStack {
                        Text(String(localized: "issue.filter.allMilestones", defaultValue: "All milestones"))
                        if milestoneFilter.isEmpty {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Button {
                    milestoneFilter = kNoMilestoneSentinel
                } label: {
                    HStack {
                        Text(String(localized: "issue.filter.noMilestone", defaultValue: "No milestone"))
                        if milestoneFilter == kNoMilestoneSentinel {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
                ForEach(availableMilestones, id: \.id) { milestone in
                    Button {
                        milestoneFilter = milestone.title
                    } label: {
                        HStack {
                            Text(milestoneMenuLabel(milestone))
                            if milestoneFilter == milestone.title {
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

            if !milestoneFilter.isEmpty {
                Button {
                    milestoneFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "issue.filter.clear", defaultValue: "Clear filter"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func milestoneMenuLabel(_ m: GitLabMilestone) -> String {
        guard let due = m.dueDate else { return m.title }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "\(m.title) • \(df.string(from: due))"
    }

    private var currentFilterLabel: String {
        if milestoneFilter.isEmpty {
            return String(localized: "issue.filter.allMilestones", defaultValue: "All milestones")
        }
        if milestoneFilter == kNoMilestoneSentinel {
            return String(localized: "issue.filter.noMilestone", defaultValue: "No milestone")
        }
        return milestoneFilter
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
            Text(String(localized: "issue.sidebar.loading", defaultValue: "Loading..."))
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
            Button(String(localized: "issue.sidebar.retry", defaultValue: "Retry")) {
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
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(
                milestoneFilter.isEmpty
                    ? String(localized: "issue.sidebar.empty", defaultValue: "No issues")
                    : String(localized: "issue.sidebar.emptyFiltered", defaultValue: "No issues match this filter")
            )
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredIssues) { issue in
                    IssueCardView(issue: issue)
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

    /// Derives the project's issue-board URL, preferring the cached project
    /// web URL (from `git remote`) and falling back to parsing any issue's
    /// `web_url` (`https://host/group/project/-/issues/<iid>`).
    private var issueBoardURL: URL? {
        if let base = state.projectWebURL, !base.isEmpty {
            return URL(string: "\(base)/-/boards")
        }
        if let sample = state.issues.first?.webURL,
           let range = sample.range(of: "/-/issues/") {
            let base = sample[..<range.lowerBound]
            return URL(string: "\(base)/-/boards")
        }
        return nil
    }
}

// MARK: - Issue Card

private struct IssueCardView: View {
    let issue: GitLabIssue
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            Text(issue.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let milestone = issue.milestone {
                milestoneBadge(milestone)
            }

            if !issue.assignees.isEmpty {
                assigneesView
            }

            if !issue.labels.isEmpty {
                labelsView
            }
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
            guard let url = URL(string: issue.webURL) else { return }
            NSWorkspace.shared.open(url)
        }
        .help(issue.webURL)
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 6) {
            stateIcon
                .font(.system(size: 12, weight: .semibold))
            Text("#\(issue.iid)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if issue.userNotesCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(issue.userNotesCount)")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                .help(String(localized: "issue.card.comments", defaultValue: "Comments"))
            }
            Spacer()
            if let updated = issue.updatedAt {
                Text(relativeTime(from: updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch issue.state {
        case "opened":
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.green)
        case "closed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.purple)
        default:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func milestoneBadge(_ m: GitLabMilestone) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "flag.fill")
                .font(.system(size: 9))
            Text(m.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            if let due = m.dueDate {
                Text("•")
                    .font(.system(size: 9))
                    .opacity(0.6)
                Text(dueDateString(due))
                    .font(.system(size: 10))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.teal)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.teal.opacity(0.15)))
        .overlay(Capsule().strokeBorder(Color.teal.opacity(0.35), lineWidth: 0.5))
    }

    private var assigneesView: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(issue.assignees.prefix(4), id: \.username) { assignee in
                    let displayName = assignee.name.isEmpty ? assignee.username : assignee.name
                    HStack(spacing: 5) {
                        AvatarBadge(name: displayName)
                        Text(displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !assignee.username.isEmpty && assignee.username != assignee.name {
                            Text("@\(assignee.username)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .help(assignee.name.isEmpty ? "@\(assignee.username)" : "\(assignee.name) (@\(assignee.username))")
                }
                if issue.assignees.count > 4 {
                    Text("+\(issue.assignees.count - 4) \(String(localized: "issue.card.moreAssignees", defaultValue: "more"))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 23)
                }
            }
        }
    }

    @ViewBuilder
    private var labelsView: some View {
        let displayed = Array(issue.labels.prefix(4))
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
            if issue.labels.count > 4 {
                Text("+\(issue.labels.count - 4)")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func dueDateString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

