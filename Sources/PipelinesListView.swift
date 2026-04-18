import SwiftUI
import AppKit

// MARK: - Pipelines State

@MainActor
final class PipelinesState: ObservableObject {
    @Published var pipelines: [GitLabPipeline] = []
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
            pipelines = []
        }
        lastDirectory = directory
        isLoading = true
        errorMessage = nil

        fetchTask = Task { [weak self] in
            let result: Result<[GitLabPipeline], Error>
            do {
                result = .success(try await fetchGitLabPipelines(in: directory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            guard !Task.isCancelled, token == self.requestCounter, directory == self.lastDirectory else {
                return
            }

            switch result {
            case .success(let items):
                self.pipelines = items
                self.errorMessage = nil
            case .failure(let error):
                self.pipelines = []
                self.errorMessage = self.messageFor(error: error)
            }
            self.isLoading = false
        }
    }

    func clear() {
        fetchTask?.cancel()
        requestCounter &+= 1
        pipelines = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
    }

    private func messageFor(error: Error) -> String {
        switch error {
        case GitLabPipelineFetchError.glabNotFound:
            return String(localized: "pipeline.error.glabNotFound", defaultValue: "glab not found")
        case GitLabPipelineFetchError.notGitLabRepo:
            return String(localized: "pipeline.error.notGitLab", defaultValue: "Not a GitLab repository")
        case GitLabPipelineFetchError.processError(let msg):
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Pipelines List View

struct PipelinesListView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var state = PipelinesState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.isLoading && state.pipelines.isEmpty {
                loadingState
            } else if let error = state.errorMessage, state.pipelines.isEmpty {
                errorState(error)
            } else if state.pipelines.isEmpty {
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
            if !state.pipelines.isEmpty {
                Text("\(state.pipelines.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
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
            Text(String(localized: "pipeline.sidebar.loading", defaultValue: "Loading..."))
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
            Button(String(localized: "pipeline.sidebar.retry", defaultValue: "Retry")) {
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
            Image(systemName: "circle.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text(String(localized: "pipeline.sidebar.empty", defaultValue: "No pipelines"))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.pipelines) { p in
                    PipelineCardView(pipeline: p)
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

// MARK: - Pipeline Card

private struct PipelineCardView: View {
    let pipeline: GitLabPipeline
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                statusBadge
                if let iid = pipeline.iid {
                    Text("#\(iid)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let updated = pipeline.updatedAt ?? pipeline.createdAt {
                    Text(relativeTime(from: updated))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(pipeline.ref)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 6) {
                Text(pipeline.shortSHA)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let source = pipeline.source, !source.isEmpty {
                    Text(friendlySource(source))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.secondary.opacity(0.12))
                        )
                }
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
            guard let url = URL(string: pipeline.webURL) else { return }
            NSWorkspace.shared.open(url)
        }
        .help(pipeline.webURL)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(statusLabel)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(statusColor.opacity(0.15))
        )
        .overlay(
            Capsule().strokeBorder(statusColor.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var statusIcon: String {
        switch pipeline.status {
        case "success": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath"
        case "pending", "created", "waiting_for_resource", "preparing": return "clock"
        case "canceled", "cancelled": return "minus.circle.fill"
        case "skipped": return "forward.fill"
        case "manual": return "hand.tap.fill"
        case "scheduled": return "calendar"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case "success": return .green
        case "failed": return .red
        case "running": return .blue
        case "pending", "created", "waiting_for_resource", "preparing": return .orange
        case "canceled", "cancelled", "skipped": return .gray
        case "manual": return .purple
        case "scheduled": return .teal
        default: return .secondary
        }
    }

    private var statusLabel: String {
        let raw = pipeline.status.replacingOccurrences(of: "_", with: " ")
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private func friendlySource(_ source: String) -> String {
        switch source {
        case "push": return "push"
        case "merge_request_event": return "MR"
        case "web": return "web"
        case "schedule": return "scheduled"
        case "api": return "api"
        case "trigger": return "trigger"
        case "pipeline": return "pipeline"
        default: return source.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
