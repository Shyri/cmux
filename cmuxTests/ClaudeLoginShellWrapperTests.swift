import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: pins the login-shell wrapping used to spawn `claude` so it
/// inherits the user's real PATH (for `npx`/`uvx`/nvm-based MCP servers).
///
/// Guards the regression from the previous session where the chat hung on
/// "Thinking…": using `-i` (interactive) forces zsh to source `.zshrc`,
/// whose TouchID/1Password/keychain plugins can block forever. The wrapper
/// MUST use `-l` only and `exec "$0" "$@"` so signals reach the CLI.
@Suite struct ClaudeLoginShellWrapperTests {
    @Test func wrapsInLoginZshWithExecForm() {
        let (url, args) = ClaudeLoginShellWrapper.wrap(
            claudePath: "/usr/local/bin/claude",
            arguments: ["-p", "--verbose"]
        )
        // On macOS /bin/zsh always exists, so we take the login-shell path.
        #expect(url.path == "/bin/zsh")
        #expect(args == ["-l", "-c", "exec \"$0\" \"$@\"", "/usr/local/bin/claude", "-p", "--verbose"])
    }

    @Test func neverUsesInteractiveFlag() {
        // The `-i` flag is the hang trigger. It must not appear anywhere.
        let (_, args) = ClaudeLoginShellWrapper.wrap(
            claudePath: "/usr/local/bin/claude",
            arguments: ["-p"]
        )
        #expect(args.contains("-i") == false)
        #expect(args.contains("-l"))
    }

    @Test func claudePathIsTheExecScriptDollarZero() {
        // `exec "$0" "$@"` means the claude path must be the first positional
        // after the `-c` script so it becomes `$0`, and the CLI args follow.
        let (_, args) = ClaudeLoginShellWrapper.wrap(
            claudePath: "/opt/homebrew/bin/claude",
            arguments: ["--resume", "abc"]
        )
        let scriptIndex = try? #require(args.firstIndex(of: "exec \"$0\" \"$@\""))
        if let scriptIndex {
            #expect(args[scriptIndex + 1] == "/opt/homebrew/bin/claude")
            #expect(args[scriptIndex + 2] == "--resume")
            #expect(args[scriptIndex + 3] == "abc")
        }
    }

    @Test func preservesEmptyArgumentList() {
        let (url, args) = ClaudeLoginShellWrapper.wrap(claudePath: "/bin/claude", arguments: [])
        #expect(url.path == "/bin/zsh")
        #expect(args == ["-l", "-c", "exec \"$0\" \"$@\"", "/bin/claude"])
    }
}
