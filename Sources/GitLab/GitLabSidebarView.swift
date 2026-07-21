import SwiftUI

enum GitLabSidebarTab: String, CaseIterable, Identifiable {
    case mergeRequests
    case issues
    case pipelines
    case releases

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mergeRequests:
            return String(localized: "gitlab.tab.mrs", defaultValue: "MRs")
        case .pipelines:
            return String(localized: "gitlab.tab.pipelines", defaultValue: "Pipelines")
        case .issues:
            return String(localized: "gitlab.tab.issues", defaultValue: "Issues")
        case .releases:
            return String(localized: "gitlab.tab.releases", defaultValue: "Releases")
        }
    }

    var icon: String {
        switch self {
        case .mergeRequests: return "arrow.triangle.merge"
        case .pipelines: return "circle.dashed"
        case .issues: return "exclamationmark.circle"
        case .releases: return "tag"
        }
    }
}

struct GitLabSidebarView: View {
    @ObservedObject var workspace: Workspace
    @State private var selectedTab: GitLabSidebarTab = .mergeRequests

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle()
                .fill(Color.darculaBorder)
                .frame(height: 1)
            content
        }
        .background(Color.darculaSidebarBackground)
        // Preserve the selected sub-tab per workspace: restore it on appear and
        // when the workspace changes, and persist every change.
        .onAppear {
            selectedTab = GitLabSidebarTabStore.shared.tab(for: workspace.id)
        }
        .onChange(of: workspace.id) { newWorkspaceId in
            selectedTab = GitLabSidebarTabStore.shared.tab(for: newWorkspaceId)
        }
        .onChange(of: selectedTab) { newTab in
            GitLabSidebarTabStore.shared.setTab(newTab, for: workspace.id)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(GitLabSidebarTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Button {
                showWorkingTreeDiff()
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.darculaForeground.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.darculaCardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(workspace.currentDirectory.isEmpty)
            .help(String(
                localized: "gitlab.sidebar.showWorkingTreeDiff",
                defaultValue: "Show working tree diff"
            ))
            .padding(.trailing, 8)
        }
    }

    private func showWorkingTreeDiff() {
        guard !workspace.currentDirectory.isEmpty else { return }
        let spec = GitDiffSpec(
            base: "HEAD",
            compare: nil,
            directory: workspace.currentDirectory,
            title: String(localized: "diff.workingTree.title", defaultValue: "Working tree")
        )
        GitDiffWindowRegistry.show(spec: spec)
    }

    private func tabButton(_ tab: GitLabSidebarTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
            }
            .foregroundStyle(isSelected ? Color.darculaAccent : Color.darculaForeground.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.darculaAccent.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.darculaAccent.opacity(0.45) : Color.clear,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .mergeRequests:
            MergeRequestsListView(workspace: workspace)
        case .pipelines:
            PipelinesListView(workspace: workspace)
        case .issues:
            IssuesListView(workspace: workspace)
        case .releases:
            ReleasesListView(workspace: workspace)
        }
    }
}

/// Persists the selected GitLab sidebar sub-tab per workspace so switching
/// workspaces and returning keeps you on the same tab (survives the
/// `.id(ws.id)` view recreation and app restarts). Mirrors the per-workspace
/// `GitLabIssueFiltersStore`.
@MainActor
final class GitLabSidebarTabStore {
    static let shared = GitLabSidebarTabStore()

    private let defaultsKey = "gitlab.sidebar.selectedTabByWorkspace"
    private var tabsByWorkspaceId: [String: String]

    private init() {
        tabsByWorkspaceId = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    func tab(for workspaceId: UUID) -> GitLabSidebarTab {
        guard let raw = tabsByWorkspaceId[workspaceId.uuidString],
              let tab = GitLabSidebarTab(rawValue: raw) else {
            return .mergeRequests
        }
        return tab
    }

    func setTab(_ tab: GitLabSidebarTab, for workspaceId: UUID) {
        guard tabsByWorkspaceId[workspaceId.uuidString] != tab.rawValue else { return }
        tabsByWorkspaceId[workspaceId.uuidString] = tab.rawValue
        UserDefaults.standard.set(tabsByWorkspaceId, forKey: defaultsKey)
    }
}
