import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression guard for the "Claude Chat panel spins on Thinking… forever"
/// class of bug.
///
/// Root cause: `drainPipesInParallel` read each pipe with
/// `readDataToEndOfFile()`, which only returns on EOF. `glab`/`git` routinely
/// spawn helper subprocesses (credential/keyring helpers, OAuth browser
/// openers) that inherit fd 1/2; when such a helper outlives the main process
/// the pipe's write end is never fully closed, so the read never sees EOF and
/// blocks its thread *forever*. These drains run on the fixed-width Swift
/// Concurrency cooperative pool (the MR-approvals fan-out spawns one per open
/// MR), so a handful of permanent blocks saturate the whole pool and wedge
/// every other `async` task — including the Claude Chat panel startup
/// (`ensureMcpServerStarted` → `ChatMcpHttpServer.start`), which then never
/// spawns `claude` and shows a permanent "Thinking…" spinner.
///
/// The fix gives the drain a hard `timeout` watchdog. `leakedWriteEnd…` is the
/// red/green witness (it hangs forever without the watchdog); `cleanEOF…`
/// pins the happy path so the watchdog can't regress normal fast returns.
///
/// Both tests run `drainPipesInParallel` on a detached thread and wait on it
/// with a *bounded* semaphore, so the failing (unfixed) case fails fast and
/// deterministically instead of relying on the test harness to interrupt a
/// synchronous C-level block (which task cancellation cannot do).
@Suite struct DrainPipesInParallelTests {

    /// Runs `drainPipesInParallel` off the test thread and returns its result,
    /// or `nil` if the drain did not return within `waitLimit` (i.e. it hung).
    private func drainWithDeadline(
        stdout: Pipe,
        stderr: Pipe,
        drainTimeout: TimeInterval,
        waitLimit: TimeInterval
    ) -> (Data, Data)? {
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: (Data, Data)? }
        let box = Box()
        Thread.detachNewThread {
            box.value = drainPipesInParallel(stdout: stdout, stderr: stderr, timeout: drainTimeout)
            done.signal()
        }
        return done.wait(timeout: .now() + waitLimit) == .success ? box.value : nil
    }

    /// A subprocess helper that inherited and kept the pipe's write end open:
    /// the read side never reaches EOF. Without the watchdog this hangs the
    /// worker thread forever (and, in aggregate, starves the cooperative pool);
    /// with it, the call must return within roughly `drainTimeout`.
    @Test(.timeLimit(.minutes(1)))
    func leakedWriteEndDoesNotHangPastTimeout() {
        let stdout = Pipe()
        let stderr = Pipe()
        let payload = Data("partial-output-no-eof".utf8)
        stdout.fileHandleForWriting.write(payload)
        // Deliberately DO NOT close the write ends — this is the leaked-helper
        // scenario. The Pipe objects stay alive for the whole test, so the
        // write ends remain open and the reads cannot see EOF on their own.

        // 0.5s drain watchdog; give it up to 10s to come back. Unfixed, the
        // drain never returns and this is nil.
        let result = drainWithDeadline(
            stdout: stdout, stderr: stderr, drainTimeout: 0.5, waitLimit: 10
        )

        #expect(result != nil, "watchdog must break the leaked-write-end deadlock, not hang")
        #expect(result?.0 == payload, "data buffered before the timeout should still be returned")
        #expect(result?.1.isEmpty ?? false)

        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    /// Happy path: a clean EOF (write end closed) must return immediately with
    /// the full output — well before the watchdog `timeout` — so the fix does
    /// not add latency to normal `glab`/`git` calls.
    @Test(.timeLimit(.minutes(1)))
    func cleanEOFReturnsFullOutputBeforeTimeout() {
        let stdout = Pipe()
        let stderr = Pipe()
        let payload = Data("hello world\n".utf8)
        stdout.fileHandleForWriting.write(payload)
        try? stdout.fileHandleForWriting.close()  // clean EOF on stdout
        try? stderr.fileHandleForWriting.close()  // clean EOF on stderr (empty)

        // Large drain timeout (30s) but a short 5s deadline: a clean EOF must
        // return promptly, never waiting for the watchdog.
        let result = drainWithDeadline(
            stdout: stdout, stderr: stderr, drainTimeout: 30, waitLimit: 5
        )

        #expect(result?.0 == payload)
        #expect(result?.1.isEmpty ?? false)
    }
}
