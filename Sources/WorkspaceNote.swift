import Foundation

struct WorkspaceNote: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var title: String
    var content: String
    var isCompleted: Bool
    let createdAt: Date

    init(id: UUID = UUID(), title: String = "", content: String = "", isCompleted: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}

struct ArchivedWorkspaceNote: Identifiable, Codable, Sendable, Equatable {
    var id: UUID { note.id }
    let note: WorkspaceNote
    let originalWorkspaceId: UUID
    let originalWorkspaceTitle: String
    let archivedAt: Date

    init(
        note: WorkspaceNote,
        originalWorkspaceId: UUID,
        originalWorkspaceTitle: String,
        archivedAt: Date = Date()
    ) {
        self.note = note
        self.originalWorkspaceId = originalWorkspaceId
        self.originalWorkspaceTitle = originalWorkspaceTitle
        self.archivedAt = archivedAt
    }
}
