import SwiftUI

enum GitLabSidebarTab: String, CaseIterable, Identifiable {
    case mergeRequests
    case pipelines
    case issues
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
            Divider()
            content
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(GitLabSidebarTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
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
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
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
