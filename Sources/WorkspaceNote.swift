import Foundation

struct WorkspaceNote: Identifiable, Equatable {
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
