import SwiftUI
import AppKit

// MARK: - Releases State

@MainActor
final class ReleasesState: ObservableObject {
    @Published var releases: [GitLabRelease] = []
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
            releases = []
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
            let result: Result<[GitLabRelease], Error>
            do {
                result = .success(try await fetchGitLabReleases(in: directory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter, directory == self.lastDirectory else {
                return
            }

            switch result {
            case .success(let items):
                self.releases = items
                self.errorMessage = nil
            case .failure(let error):
                self.releases = []
                self.errorMessage = self.messageFor(error: error)
            }
            self.isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        remoteTask?.cancel()
        requestCounter &+= 1
        releases = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
        projectWebURL = nil
    }

    private func messageFor(error: Error) -> String {
        switch error {
        case GitLabReleaseFetchError.glabNotFound:
            return String(localized: "release.error.glabNotFound", defaultValue: "glab not found")
        case GitLabReleaseFetchError.notGitLabRepo:
            return String(localized: "release.error.notGitLab", defaultValue: "Not a GitLab repository")
        case GitLabReleaseFetchError.processError(let msg):
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Releases List View

struct ReleasesListView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var state = ReleasesState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.isLoading && state.releases.isEmpty {
                loadingState
            } else if let error = state.errorMessage, state.releases.isEmpty {
                errorState(error)
            } else if state.releases.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onAppear { refreshIfNeeded() }
        .onChange(of: workspace.currentDirectory) { _ in refreshIfNeeded() }
    }

    private var header: some View {
        HStack {
            if !state.releases.isEmpty {
                Text("\(state.releases.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
            if let url = panelURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(
                    localized: "release.sidebar.openPanel",
                    defaultValue: "Open releases in browser"
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

    private var loadingState: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
            Text(String(localized: "release.sidebar.loading", defaultValue: "Loading..."))
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
            Button(String(localized: "release.sidebar.retry", defaultValue: "Retry")) {
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
            Image(systemName: "shippingbox")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(String(localized: "release.sidebar.empty", defaultValue: "No releases"))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.releases) { release in
                    ReleaseCardView(release: release)
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

    private var panelURL: URL? {
        guard let base = state.projectWebURL, !base.isEmpty else { return nil }
        return URL(string: "\(base)/-/releases")
    }
}

// MARK: - Release Card

private struct ReleaseCardView: View {
    let release: GitLabRelease
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(release.tagName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if release.upcomingRelease {
                    Text(String(
                        localized: "release.card.upcoming",
                        defaultValue: "Upcoming"
                    ))
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
                if let date = release.releasedAt ?? release.createdAt {
                    Text(relativeTime(from: date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(fullDate(date))
                }
            }

            if !release.name.isEmpty && release.name != release.tagName {
                Text(release.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !release.description.isEmpty {
                Text(firstLine(release.description))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !release.assetLinks.isEmpty || release.sourceCount > 0 {
                assetsSection
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
            guard let url = URL(string: release.webURL) else { return }
            NSWorkspace.shared.open(url)
        }
        .contextMenu {
            Button {
                guard let url = URL(string: release.webURL) else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label(
                    String(localized: "release.card.openBrowser", defaultValue: "Open in Browser"),
                    systemImage: "safari"
                )
            }
            if !release.webURL.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(release.webURL, forType: .string)
                } label: {
                    Label(
                        String(localized: "release.card.copyLink", defaultValue: "Copy Link"),
                        systemImage: "link"
                    )
                }
            }
            if !release.assetLinks.isEmpty {
                Divider()
                Menu {
                    ForEach(release.assetLinks) { asset in
                        Button(asset.name) {
                            guard let url = URL(string: asset.url) else { return }
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Label(
                        String(localized: "release.card.assets", defaultValue: "Assets"),
                        systemImage: "shippingbox"
                    )
                }
            }
        }
        .help(release.webURL)
    }

    @ViewBuilder
    private var assetsSection: some View {
        HStack(spacing: 6) {
            if !release.assetLinks.isEmpty {
                assetBadge(
                    icon: "shippingbox",
                    label: "\(release.assetLinks.count) \(release.assetLinks.count == 1 ? "asset" : "assets")",
                    color: .accentColor
                )
            }
            if release.sourceCount > 0 {
                assetBadge(
                    icon: "doc.zipper",
                    label: "\(release.sourceCount) \(release.sourceCount == 1 ? "source" : "sources")",
                    color: .gray
                )
            }
        }
    }

    private func assetBadge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.12))
        )
    }

    private func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = trimmed.firstIndex(of: "\n") {
            return String(trimmed[..<nl])
        }
        return trimmed
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func fullDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }
}
