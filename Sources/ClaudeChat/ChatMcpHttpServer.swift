import Foundation
import Network

/// Delegate that surfaces incoming MCP tool calls to the UI layer.
@MainActor
protocol ChatMcpHttpServerDelegate: AnyObject {
    func server(
        _ server: ChatMcpHttpServer,
        didReceiveApproval request: ChatApprovalRequest,
        completion: @escaping (ChatApprovalResponse) -> Void
    )
    func server(
        _ server: ChatMcpHttpServer,
        didReceiveQuestion request: ChatUserQuestionRequest,
        completion: @escaping (ChatUserQuestionResponse) -> Void
    )
    func server(
        _ server: ChatMcpHttpServer,
        didReceiveSetCwd path: String,
        completion: @escaping (Result<String, Error>) -> Void
    )
}

/// Minimal HTTP server speaking enough of MCP's "Streamable HTTP" transport
/// for `claude -p --mcp-config ... --permission-prompt-tool ...` to drive
/// inline Allow/Deny UI in cmux. One server per chat panel.
///
/// The implementation handles:
/// - `initialize` → returns server info + capabilities (`tools`)
/// - `notifications/initialized` → no-op
/// - `tools/list` → returns `approval_prompt` and `ask_user_question`
/// - `tools/call` → dispatches to the panel via the delegate, suspends until
///   the user resolves it, then replies with the MCP-shaped tool result.
///
/// Each HTTP request is treated as a single JSON-RPC message; the connection
/// is closed after one response. Sufficient for `claude` which opens a fresh
/// connection per call.
final class ChatMcpHttpServer {
    weak var delegate: ChatMcpHttpServerDelegate?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.cmux.claudechat.mcp", qos: .userInitiated)

    /// Bound port. Available after `start()`.
    private(set) var port: UInt16 = 0

    /// `http://127.0.0.1:<port>/mcp` — what we put in the mcp-config.
    var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Listener binds to wildcard; we use a localhost URL in the
        // mcp-config so claude will dial 127.0.0.1 directly. Other local
        // processes could reach it too — acceptable for an MVP, since the
        // worst case is a peer denying their own tool calls.
        self.listener = try NWListener(using: parameters)
    }

    /// Start listening on a random loopback port. Resolves once the kernel
    /// has assigned a port (state == .ready). Never blocks the calling
    /// thread — internally hops via NWListener's queue.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Use a manual flag so we never resume the continuation more
            // than once even if NWListener emits multiple state updates.
            let lock = NSLock()
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                lock.lock()
                let alreadyResumed = resumed
                resumed = true
                lock.unlock()
                guard !alreadyResumed else { return }
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    resumeOnce(.failure(ServerError.bindFailed))
                    return
                }
                switch state {
                case .ready:
                    if let p = self.listener.port?.rawValue {
                        self.port = p
                    }
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(ServerError.bindFailed))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard ChatMcpHttpServer.isLoopbackEndpoint(connection.endpoint) else {
                    connection.cancel()
                    return
                }
                self?.handleConnection(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    enum ServerError: Error {
        case bindFailed
    }

    // MARK: - Connection lifecycle

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, accumulated: Data())
    }

    private func readRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                _ = error
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if let parsed = HTTPRequestParser.parse(buffer) {
                self.dispatch(parsed: parsed, on: connection)
            } else if isComplete {
                self.respond(on: connection, status: 400, body: nil)
            } else {
                self.readRequest(on: connection, accumulated: buffer)
            }
        }
    }

    private func dispatch(parsed: HTTPRequestParser.ParsedRequest, on connection: NWConnection) {
        guard parsed.method == "POST" else {
            respond(on: connection, status: 405, body: nil)
            return
        }
        guard let body = parsed.body, !body.isEmpty else {
            respond(on: connection, status: 400, body: nil)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(on: connection, status: 400, body: nil)
            return
        }
        let method = json["method"] as? String ?? ""
        let requestId = json["id"]
        let params = json["params"] as? [String: Any]
        let acceptsSSE = (parsed.headers["accept"] ?? "").lowercased().contains("text/event-stream")

        switch method {
        case "initialize":
            sendJsonRpcResult(requestId, result: makeInitializeResult(), on: connection)
        case "notifications/initialized", "notifications/cancelled":
            // Notifications carry no `id`; reply 202 Accepted with empty body.
            respond(on: connection, status: 202, body: nil)
        case "tools/list":
            sendJsonRpcResult(requestId, result: makeToolsListResult(), on: connection)
        case "tools/call":
            handleToolsCall(requestId: requestId, params: params, connection: connection, acceptsSSE: acceptsSSE)
        case "ping":
            sendJsonRpcResult(requestId, result: [:], on: connection)
        default:
            sendJsonRpcError(requestId, code: -32601, message: "Method not found: \(method)", on: connection)
        }
    }

    // MARK: - MCP responses

    private func makeInitializeResult() -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "cmux", "version": "1.0.0"]
        ]
    }

    private func makeToolsListResult() -> [String: Any] {
        let approvalPrompt: [String: Any] = [
            "name": "approval_prompt",
            "description": "Request user approval before invoking a tool. Returns {behavior, updatedInput?}.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tool_name": ["type": "string"],
                    "input": ["type": "object"]
                ],
                "required": ["tool_name", "input"]
            ]
        ]
        let askUser: [String: Any] = [
            "name": "ask_user_question",
            "description": "Ask the human one or more multiple-choice questions in a single tool call. Each question carries a short header label, the question text, an array of distinct mutually exclusive options, and an optional multiSelect flag. Use this whenever you need to disambiguate intent or get a quick decision.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "questions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "header": ["type": "string", "description": "Very short label (max 12 chars), e.g. 'Auth method', 'Library'."],
                                "question": ["type": "string"],
                                "multiSelect": ["type": "boolean"],
                                "options": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "label": ["type": "string"],
                                            "description": ["type": "string"]
                                        ],
                                        "required": ["label"]
                                    ]
                                ]
                            ],
                            "required": ["question", "options"]
                        ]
                    ]
                ],
                "required": ["questions"]
            ]
        ]
        let setCwd: [String: Any] = [
            "name": "set_cwd",
            "description": "Notify cmux that your effective working directory has changed. Call this with an absolute path after using EnterWorktree, ExitWorktree, or any other tool that changes your cwd, so the chat header (path + git branch chip) stays in sync. Idempotent — safe to call even if cmux already detected the change.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute filesystem path of the new working directory."]
                ],
                "required": ["path"]
            ]
        ]
        return ["tools": [approvalPrompt, askUser, setCwd]]
    }

    private func handleToolsCall(requestId: Any?, params: [String: Any]?, connection: NWConnection, acceptsSSE: Bool) {
        let name = (params?["name"] as? String) ?? ""
        let args = (params?["arguments"] as? [String: Any]) ?? [:]
        switch name {
        case "approval_prompt":
            handleApprovalPrompt(
                requestId: requestId,
                args: args,
                connection: connection,
                stream: SseStream.openIfNeeded(acceptsSSE: acceptsSSE, on: connection, queue: queue)
            )
        case "ask_user_question":
            handleAskUserQuestion(
                requestId: requestId,
                args: args,
                connection: connection,
                stream: SseStream.openIfNeeded(acceptsSSE: acceptsSSE, on: connection, queue: queue)
            )
        case "set_cwd":
            handleSetCwd(
                requestId: requestId,
                args: args,
                connection: connection,
                stream: SseStream.openIfNeeded(acceptsSSE: acceptsSSE, on: connection, queue: queue)
            )
        default:
            sendJsonRpcError(requestId, code: -32602, message: "Unknown tool: \(name)", on: connection)
        }
    }

    private func handleApprovalPrompt(requestId: Any?, args: [String: Any], connection: NWConnection, stream: SseStream?) {
        let toolName = (args["tool_name"] as? String) ?? "unknown"
        let inputAny = args["input"] ?? [:]
        let inputJSON = ChatMcpHttpServer.encodeJSONPretty(inputAny)
        let request = ChatApprovalRequest(
            id: UUID().uuidString,
            toolName: toolName,
            inputJSON: inputJSON
        )

        ChatRunnerDebugLog.shared.appendStdoutLine(
            "MCP approval_prompt request id=\(request.id) tool=\(toolName)"
        )
        let startedAt = Date()

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else {
                self?.queue.async {
                    self?.replyApproval(
                        .deny(reason: "cmux chat panel is not available"),
                        originalInput: inputAny,
                        requestId: requestId,
                        on: connection,
                        stream: stream
                    )
                }
                return
            }
            delegate.server(self, didReceiveApproval: request) { response in
                self.queue.async {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    ChatRunnerDebugLog.shared.appendStdoutLine(
                        String(format: "MCP approval_prompt resolved id=\(request.id) behavior=\(response.behavior.rawValue) waited=%.1fs", elapsed)
                    )
                    self.replyApproval(
                        response,
                        originalInput: inputAny,
                        requestId: requestId,
                        on: connection,
                        stream: stream
                    )
                }
            }
        }
    }

    private func handleAskUserQuestion(requestId: Any?, args: [String: Any], connection: NWConnection, stream: SseStream?) {
        let requestUUID = UUID().uuidString
        var subQuestions: [ChatUserQuestionRequest.SubQuestion] = []

        // Preferred shape: { questions: [{header, question, options, multiSelect}, ...] }
        if let questionsRaw = args["questions"] as? [[String: Any]] {
            for (idx, q) in questionsRaw.enumerated() {
                if let parsed = ChatMcpHttpServer.parseSubQuestion(q, requestId: requestUUID, index: idx) {
                    subQuestions.append(parsed)
                }
            }
        } else {
            // Backwards compat with the earlier flat shape:
            // { question, options, multi_select } → single sub-question.
            if let parsed = ChatMcpHttpServer.parseSubQuestion(args, requestId: requestUUID, index: 0) {
                subQuestions.append(parsed)
            }
        }

        guard !subQuestions.isEmpty else {
            sendJsonRpcError(requestId, code: -32602, message: "ask_user_question: no questions provided", on: connection)
            return
        }

        let request = ChatUserQuestionRequest(id: requestUUID, questions: subQuestions)

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else {
                self?.queue.async {
                    self?.replyAskUser(
                        ChatUserQuestionResponse(answers: Array(repeating: [], count: subQuestions.count)),
                        requestId: requestId,
                        on: connection,
                        stream: stream
                    )
                }
                return
            }
            delegate.server(self, didReceiveQuestion: request) { response in
                self.queue.async {
                    self.replyAskUser(response, requestId: requestId, on: connection, stream: stream)
                }
            }
        }
    }

    private static func parseSubQuestion(
        _ dict: [String: Any],
        requestId: String,
        index: Int
    ) -> ChatUserQuestionRequest.SubQuestion? {
        guard let questionText = dict["question"] as? String, !questionText.isEmpty else { return nil }
        let header = (dict["header"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let multiSelect = (dict["multiSelect"] as? Bool)
            ?? (dict["multi_select"] as? Bool)
            ?? false
        let optionsRaw = (dict["options"] as? [[String: Any]]) ?? []
        let options: [ChatUserQuestionRequest.Option] = optionsRaw.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            return .init(label: label, description: item["description"] as? String)
        }
        return .init(
            id: "\(requestId)·\(index)",
            header: header,
            question: questionText,
            options: options,
            multiSelect: multiSelect
        )
    }

    private func replyApproval(
        _ response: ChatApprovalResponse,
        originalInput: Any,
        requestId: Any?,
        on connection: NWConnection,
        stream: SseStream?
    ) {
        // MCP tool result shape: { content: [{type:"text", text: "<json>"}], isError: false }
        // Claude Code's permission-prompt-tool requires:
        //   { "behavior": "allow", "updatedInput": {...} }   ← updatedInput REQUIRED
        //   { "behavior": "deny",  "message": "..." }
        // If `updatedInput` is missing on allow, claude treats the response
        // as malformed and falls through to a deny. Echo the original input
        // when the user did not edit it.
        var payload: [String: Any] = ["behavior": response.behavior.rawValue]
        if response.behavior == .allow {
            if let updated = response.updatedInputJSON,
               let data = updated.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload["updatedInput"] = obj
            } else if let originalDict = originalInput as? [String: Any] {
                payload["updatedInput"] = originalDict
            } else {
                payload["updatedInput"] = [String: Any]()
            }
        } else {
            payload["message"] = response.denyReason
                ?? "User denied the tool invocation in cmux chat."
        }
        let payloadText = ChatMcpHttpServer.encodeJSONCompact(payload)
        let result: [String: Any] = [
            "content": [["type": "text", "text": payloadText]],
            "isError": false
        ]
        if let stream {
            stream.finish(with: makeJsonRpcResult(requestId, result: result))
        } else {
            sendJsonRpcResult(requestId, result: result, on: connection)
        }
    }

    private func handleSetCwd(requestId: Any?, args: [String: Any], connection: NWConnection, stream: SseStream?) {
        let rawPath = (args["path"] as? String) ?? ""
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            sendJsonRpcError(requestId, code: -32602, message: "set_cwd: missing or empty `path`", on: connection)
            return
        }
        ChatRunnerDebugLog.shared.appendStdoutLine("MCP set_cwd request path=\(path)")

        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else {
                self?.queue.async {
                    self?.replySetCwd(.failure(SetCwdError.unavailable), requestId: requestId, on: connection, stream: stream)
                }
                return
            }
            delegate.server(self, didReceiveSetCwd: path) { result in
                self.queue.async {
                    self.replySetCwd(result, requestId: requestId, on: connection, stream: stream)
                }
            }
        }
    }

    private enum SetCwdError: Error {
        case unavailable
    }

    private func replySetCwd(
        _ result: Result<String, Error>,
        requestId: Any?,
        on connection: NWConnection,
        stream: SseStream?
    ) {
        let payloadText: String
        let isError: Bool
        switch result {
        case .success(let acceptedPath):
            payloadText = ChatMcpHttpServer.encodeJSONCompact([
                "ok": true,
                "path": acceptedPath
            ])
            isError = false
        case .failure(let error):
            let message: String
            if case SetCwdError.unavailable = error {
                message = "cmux chat panel is not available"
            } else {
                message = (error as NSError).localizedDescription
            }
            payloadText = ChatMcpHttpServer.encodeJSONCompact([
                "ok": false,
                "error": message
            ])
            isError = true
        }
        let mcpResult: [String: Any] = [
            "content": [["type": "text", "text": payloadText]],
            "isError": isError
        ]
        if let stream {
            stream.finish(with: makeJsonRpcResult(requestId, result: mcpResult))
        } else {
            sendJsonRpcResult(requestId, result: mcpResult, on: connection)
        }
    }

    private func replyAskUser(_ response: ChatUserQuestionResponse, requestId: Any?, on connection: NWConnection, stream: SseStream?) {
        // Each answers[i] is the labels selected for sub-question i. Flatten
        // into a structured payload claude can parse easily, plus a human
        // string for fallback rendering.
        let payloadAnswers = response.answers.map { labels -> [String: Any] in
            ["selected": labels]
        }
        let payload: [String: Any] = ["answers": payloadAnswers]
        let payloadText = ChatMcpHttpServer.encodeJSONCompact(payload)
        let result: [String: Any] = [
            "content": [["type": "text", "text": payloadText]],
            "isError": false
        ]
        if let stream {
            stream.finish(with: makeJsonRpcResult(requestId, result: result))
        } else {
            sendJsonRpcResult(requestId, result: result, on: connection)
        }
    }

    /// Build the JSON-RPC envelope without writing to the wire — used by
    /// `SseStream.finish` to ship the final message inside an SSE event.
    private func makeJsonRpcResult(_ id: Any?, result: [String: Any]) -> Data {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        return (try? JSONSerialization.data(withJSONObject: msg, options: [])) ?? Data()
    }

    // MARK: - JSON-RPC response helpers

    private func sendJsonRpcResult(_ id: Any?, result: [String: Any], on connection: NWConnection) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        let body = (try? JSONSerialization.data(withJSONObject: msg, options: [])) ?? Data()
        respond(on: connection, status: 200, body: body)
    }

    private func sendJsonRpcError(_ id: Any?, code: Int, message: String, on connection: NWConnection) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { msg["id"] = id }
        let body = (try? JSONSerialization.data(withJSONObject: msg, options: [])) ?? Data()
        respond(on: connection, status: 200, body: body)
    }

    // MARK: - HTTP response

    private func respond(on connection: NWConnection, status: Int, body: Data?) {
        var head = "HTTP/1.1 \(status) \(httpStatusText(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        let bytesOut = data.count
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                ChatRunnerDebugLog.shared.appendStdoutLine(
                    "MCP HTTP response send error: \(error.localizedDescription) (status=\(status))"
                )
            } else {
                ChatRunnerDebugLog.shared.appendStdoutLine(
                    "MCP HTTP response sent status=\(status) bytes=\(bytesOut)"
                )
            }
            connection.cancel()
        })
    }

    private func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Status"
        }
    }

    // MARK: - JSON helpers

    private static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let v4):
            return v4 == .loopback
        case .ipv6(let v6):
            // ::1 (IPv6 loopback) and IPv4-mapped 127.0.0.1.
            let parts = v6.rawValue.map { $0 }
            let isIPv6Loopback = (parts.count == 16) && (parts.prefix(15).allSatisfy { $0 == 0 } && parts.last == 1)
            let isIPv4MappedLoopback = (parts.count == 16)
                && parts[0..<10].allSatisfy { $0 == 0 }
                && parts[10] == 0xFF && parts[11] == 0xFF
                && parts[12] == 127 && parts[13] == 0 && parts[14] == 0 && parts[15] == 1
            return isIPv6Loopback || isIPv4MappedLoopback
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    static func encodeJSONCompact(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func encodeJSONPretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - SSE keepalive stream

/// Long-lived HTTP/SSE response used while we wait for the user to
/// answer an interactive MCP tool call (`approval_prompt`,
/// `ask_user_question`). Without this, Claude Code times out the
/// blocking JSON response after ~60 seconds and retries the same tool
/// call, which surfaces as duplicate prompts in the UI.
///
/// Lifecycle:
/// 1. `openIfNeeded` writes the SSE response head and starts a
///    keepalive timer that sends a `: ping` comment every 25 s. The
///    comment is ignored by clients but resets the read timeout.
/// 2. `finish(with:)` writes one final `event: message\ndata: <json>\n`
///    block (the JSON-RPC response payload) and closes the connection.
///
/// If the client did not advertise `Accept: text/event-stream`, no
/// SSE stream is opened and the existing one-shot JSON path is used.
final class SseStream {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var finished = false

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func openIfNeeded(
        acceptsSSE: Bool,
        on connection: NWConnection,
        queue: DispatchQueue
    ) -> SseStream? {
        guard acceptsSSE else { return nil }
        let stream = SseStream(connection: connection, queue: queue)
        stream.writeHead()
        stream.startKeepalive()
        return stream
    }

    private func writeHead() {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n"
        head += "\r\n"
        // SSE preamble: a comment line so any intermediary that buffers
        // the first chunk gets it before our keepalive timer fires.
        head += ": cmux mcp keepalive stream\n\n"
        let data = Data(head.utf8)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let comment = ": ping\n\n"
            self.connection.send(content: Data(comment.utf8), completion: .contentProcessed { _ in })
        }
        timer.resume()
        self.timer = timer
    }

    /// Send the JSON-RPC response body as a single SSE `message` event
    /// and close the connection.
    func finish(with body: Data) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        var event = "event: message\n"
        event += "data: "
        var payload = Data(event.utf8)
        payload.append(body)
        payload.append(Data("\n\n".utf8))
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    deinit {
        timer?.cancel()
    }
}

// MARK: - Minimal HTTP/1.1 request parser

enum HTTPRequestParser {
    struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    static func parse(_ data: Data) -> ParsedRequest? {
        // Find header/body separator (\r\n\r\n).
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let headerEnd = firstRange(of: separator, in: data) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyAvailable = data.distance(from: bodyStart, to: data.endIndex)
        if contentLength > 0 && bodyAvailable < contentLength {
            return nil  // need more bytes
        }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = contentLength > 0 ? data.subdata(in: bodyStart..<bodyEnd) : nil

        return ParsedRequest(method: method, path: path, headers: headers, body: body)
    }

    private static func firstRange(of needle: [UInt8], in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let upper = haystack.endIndex - needle.count
        var i = haystack.startIndex
        while i <= upper {
            var j = 0
            while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count {
                return i..<(i + needle.count)
            }
            i += 1
        }
        return nil
    }
}
