import Foundation

/// Append-only debug log for the Claude Chat panel. Writes one human-readable
/// log file per cmux process at `/tmp/cmux-claudechat.log`. Used to diagnose
/// tool-use routing issues (e.g. claude calling a built-in tool we tried to
/// disallow). Cheap when the file isn't being read, never blocks the caller.
final class ChatRunnerDebugLog {
    static let shared = ChatRunnerDebugLog()

    private let queue = DispatchQueue(label: "com.cmux.claudechat.debug-log", qos: .utility)
    private let url: URL

    private init() {
        let path = "/tmp/cmux-claudechat.log"
        self.url = URL(fileURLWithPath: path)
        // Truncate at startup so each cmux launch starts from a clean log.
        try? Data().write(to: url)
    }

    func appendInvocation(executable: String, arguments: [String], cwd: String) {
        let pretty = arguments
            .map { arg in arg.contains(" ") ? "\"\(arg)\"" : arg }
            .joined(separator: " ")
        append(
            """
            ─── claude spawn at \(Self.timestamp()) ───
            cwd: \(cwd)
            cmd: \(executable) \(pretty)

            """
        )
    }

    func appendStdoutLine(_ line: String) {
        append("stdout: \(line)\n")
    }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        queue.async { [url] in
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url, options: .atomic)
                return
            }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}
