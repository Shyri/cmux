import SwiftUI
import AppKit

// MARK: - Pipelines State

@MainActor
final class PipelinesState: ObservableObject {
    @Published var pipelines: [GitLabPipeline] = []
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
            pipelines = []
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
        remoteTask?.cancel()
        requestCounter &+= 1
        pipelines = []
        errorMessage = nil
        isLoading = false
        lastDirectory = nil
        projectWebURL = nil
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
                    localized: "pipeline.sidebar.openPanel",
                    defaultValue: "Open pipelines in browser"
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
                    PipelineCardView(pipeline: p, directory: workspace.currentDirectory)
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
        return URL(string: "\(base)/-/pipelines")
    }
}

// MARK: - Pipeline Card

private struct PipelineCardView: View {
    let pipeline: GitLabPipeline
    let directory: String
    @State private var isHovered = false
    @State private var showingJobsPopover = false
    @State private var jobs: [GitLabJob] = []
    @State private var jobsLoading = false
    @State private var jobsError: String?
    @State private var downloadingJob: String?

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
                artifactsButton
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
                .fill(isHovered ? Color.darculaCardHover : Color.darculaCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.darculaBorder, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard let url = URL(string: pipeline.webURL) else { return }
            NSWorkspace.shared.open(url)
        }
        .help(pipeline.webURL)
    }

    private var artifactsButton: some View {
        Button {
            showingJobsPopover.toggle()
            if showingJobsPopover && jobs.isEmpty && !jobsLoading {
                loadJobs()
            }
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "pipeline.artifacts.download", defaultValue: "Download artifacts"))
        .popover(isPresented: $showingJobsPopover, arrowEdge: .bottom) {
            jobsPopover
        }
    }

    @ViewBuilder
    private var jobsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "pipeline.artifacts.title", defaultValue: "Artifacts"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    jobs = []
                    jobsError = nil
                    loadJobs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(jobsLoading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()

            if jobsLoading {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text(String(localized: "pipeline.artifacts.loading", defaultValue: "Loading jobs..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else if let err = jobsError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: 280, alignment: .leading)
            } else {
                let withArtifacts = jobs.filter { $0.hasArtifacts }
                if withArtifacts.isEmpty {
                    Text(String(
                        localized: "pipeline.artifacts.none",
                        defaultValue: "No jobs with artifacts"
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(withArtifacts) { job in
                                jobRow(job)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .frame(minWidth: 240)
    }

    private func jobRow(_ job: GitLabJob) -> some View {
        Button {
            triggerDownload(job: job)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !job.stage.isEmpty {
                        Text(job.stage)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if downloadingJob == job.name {
                    ProgressView().scaleEffect(0.5)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloadingJob != nil)
    }

    private func loadJobs() {
        jobsLoading = true
        jobsError = nil
        Task {
            do {
                let fetched = try await fetchJobsForPipeline(pipelineID: pipeline.id, in: directory)
                await MainActor.run {
                    jobs = fetched
                    jobsLoading = false
                }
            } catch {
                await MainActor.run {
                    jobsError = (error as? GitLabPipelineFetchError).map { err in
                        if case let .processError(m) = err { return m.trimmingCharacters(in: .whitespacesAndNewlines) }
                        return error.localizedDescription
                    } ?? error.localizedDescription
                    jobsLoading = false
                }
            }
        }
    }

    private func triggerDownload(job: GitLabJob) {
        downloadingJob = job.name
        Task {
            do {
                let dest = try await downloadArtifacts(
                    ref: pipeline.ref,
                    jobName: job.name,
                    in: directory
                )
                await MainActor.run {
                    downloadingJob = nil
                    showingJobsPopover = false
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    downloadingJob = nil
                    let msg: String
                    if let err = error as? GitLabPipelineFetchError, case let .processError(m) = err {
                        msg = m.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        msg = error.localizedDescription
                    }
                    let alert = NSAlert()
                    alert.messageText = String(
                        localized: "pipeline.artifacts.downloadFailed",
                        defaultValue: "Failed to download artifacts"
                    )
                    alert.informativeText = msg
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
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
