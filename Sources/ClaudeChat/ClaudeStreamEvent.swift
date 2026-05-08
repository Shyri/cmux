import Foundation

/// One decoded line of `claude -p --output-format stream-json --verbose`.
///
/// The stream contains four interesting top-level shapes:
/// - `system` (subtype "init"): emitted once at the start of every turn,
///   carries the session id we need for `--resume` on subsequent turns.
/// - `assistant`: a single assistant message with one or more content
///   blocks (text or tool_use). With `--include-partial-messages` enabled
///   each block can be split across multiple `stream_event` deltas, but
///   phase 2 keeps things simple by consuming whole messages.
/// - `user`: a synthetic user message containing tool_result blocks for
///   each tool the assistant invoked.
/// - `result`: emitted once at the end of the turn with the success flag,
///   total cost and the final text answer.
///
/// Anything else is mapped to `.other` so future schema additions never
/// crash the chat.
enum ClaudeStreamEvent {
    case systemInit(sessionId: String, model: String?, cwd: String?)
    case assistant(messageId: String?, blocks: [ChatMessageBlock])
    case user(blocks: [ChatMessageBlock])
    case result(isError: Bool, sessionId: String?, errorMessage: String?, totalCostUSD: Double?)
    case other(typeName: String)

    enum ParseError: Error {
        case notJSON
        case missingType
        case malformed(String)
    }

    /// Parse a single NDJSON line. Empty/whitespace lines return nil.
    static func parse(line: String) throws -> ClaudeStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            throw ParseError.notJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ParseError.notJSON
        }
        guard let dict = object as? [String: Any] else {
            throw ParseError.malformed("top level is not an object")
        }
        guard let type = dict["type"] as? String else {
            throw ParseError.missingType
        }
        switch type {
        case "system":
            return parseSystem(dict)
        case "assistant":
            return parseAssistant(dict)
        case "user":
            return parseUser(dict)
        case "result":
            return parseResult(dict)
        default:
            return .other(typeName: type)
        }
    }

    // MARK: - Type-specific parsers

    private static func parseSystem(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let subtype = dict["subtype"] as? String
        let sessionId = dict["session_id"] as? String ?? ""
        let model = dict["model"] as? String
        let cwd = dict["cwd"] as? String
        if subtype == "init" {
            return .systemInit(sessionId: sessionId, model: model, cwd: cwd)
        }
        return .other(typeName: "system." + (subtype ?? "?"))
    }

    private static func parseAssistant(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let message = dict["message"] as? [String: Any] ?? [:]
        let messageId = message["id"] as? String
        let contentArray = message["content"] as? [[String: Any]] ?? []
        let blocks = contentArray.compactMap { decodeContentBlock($0) }
        return .assistant(messageId: messageId, blocks: blocks)
    }

    private static func parseUser(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let message = dict["message"] as? [String: Any] ?? [:]
        let contentArray = message["content"] as? [[String: Any]] ?? []
        let blocks = contentArray.compactMap { decodeContentBlock($0) }
        return .user(blocks: blocks)
    }

    private static func parseResult(_ dict: [String: Any]) -> ClaudeStreamEvent {
        let isError = (dict["is_error"] as? Bool) ?? false
        let sessionId = dict["session_id"] as? String
        let errorMessage: String?
        if isError {
            errorMessage = (dict["error"] as? String) ?? (dict["result"] as? String)
        } else {
            errorMessage = nil
        }
        let totalCostUSD = dict["total_cost_usd"] as? Double
        return .result(
            isError: isError,
            sessionId: sessionId,
            errorMessage: errorMessage,
            totalCostUSD: totalCostUSD
        )
    }

    // MARK: - Content block decoding

    private static func decodeContentBlock(_ block: [String: Any]) -> ChatMessageBlock? {
        guard let type = block["type"] as? String else { return nil }
        switch type {
        case "text":
            guard let text = block["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .text(text)
        case "tool_use":
            let id = (block["id"] as? String) ?? ""
            let name = (block["name"] as? String) ?? "unknown"
            let inputAny = block["input"] ?? [:]
            let inputJSON = encodeJSON(inputAny)
            return .toolUse(.init(id: id, name: name, inputJSON: inputJSON))
        case "tool_result":
            let toolUseId = (block["tool_use_id"] as? String) ?? ""
            let isError = (block["is_error"] as? Bool) ?? false
            let content = stringifyToolResultContent(block["content"])
            return .toolResult(.init(toolUseId: toolUseId, content: content, isError: isError))
        default:
            return nil
        }
    }

    private static func stringifyToolResultContent(_ raw: Any?) -> String {
        if let string = raw as? String { return string }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if let type = item["type"] as? String, type == "text" {
                    return item["text"] as? String
                }
                return nil
            }
            .joined(separator: "\n")
        }
        return encodeJSON(raw ?? "")
    }

    private static func encodeJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            // JSONSerialization rejects scalars at top level. Wrap in an array
            // and unwrap so we still get a stable JSON string for primitives.
            if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
               let wrapped = String(data: data, encoding: .utf8),
               wrapped.hasPrefix("["), wrapped.hasSuffix("]") {
                return String(wrapped.dropFirst().dropLast())
            }
            return ""
        }
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .prettyPrinted]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: opts) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
