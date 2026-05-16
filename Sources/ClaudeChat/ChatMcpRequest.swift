import Foundation

/// Request the MCP server raises to the chat panel when claude calls the
/// `approval_prompt` tool. The panel surfaces it as inline Allow/Deny UI.
struct ChatApprovalRequest: Identifiable, Equatable {
    let id: String
    let toolName: String
    /// Tool input as a pretty-printed JSON string for display.
    let inputJSON: String
}

/// User's reply to an `approval_prompt`. The MCP server forwards this to
/// claude as the tool result.
struct ChatApprovalResponse: Equatable {
    let behavior: Behavior
    /// Optional updated tool input (JSON string) when behavior == .allow.
    let updatedInputJSON: String?
    /// Optional reason string when behavior == .deny.
    let denyReason: String?

    enum Behavior: String, Equatable {
        case allow
        case deny
    }

    static let allow = ChatApprovalResponse(behavior: .allow, updatedInputJSON: nil, denyReason: nil)
    static func deny(reason: String? = nil) -> ChatApprovalResponse {
        ChatApprovalResponse(behavior: .deny, updatedInputJSON: nil, denyReason: reason)
    }
}

/// Request the MCP server raises to the chat panel when claude calls the
/// `ask_user_question` tool. Claude can ask one or more sub-questions in a
/// single tool call; the panel renders them stacked and submits a combined
/// reply.
struct ChatUserQuestionRequest: Identifiable, Equatable {
    let id: String
    let questions: [SubQuestion]

    struct SubQuestion: Identifiable, Equatable {
        let id: String
        let header: String?
        let question: String
        let options: [Option]
        let multiSelect: Bool
    }

    struct Option: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let description: String?
    }
}

/// User's reply. Each entry corresponds to a sub-question in `questions[]`,
/// in the same order; an entry is the list of selected labels for that
/// sub-question (length 1 for single-select, ≥1 for multi-select, empty
/// when the user dismissed without choosing).
struct ChatUserQuestionResponse: Equatable {
    let answers: [[String]]
}
