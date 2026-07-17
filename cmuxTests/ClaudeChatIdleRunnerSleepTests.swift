import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: guards the invariant that lets an idle chat panel terminate
/// its `claude` subprocess to reclaim memory (~250-300 MB each) and respawn it
/// transparently via `--resume`. The predicate must never green-light sleeping
/// while a turn is in flight or while the user owes an approval / question /
/// queued draft — otherwise sleeping would drop live work.
@Suite struct ClaudeChatIdleRunnerSleepTests {
    @Test func sleepsWhenIdleRunningAndNothingPending() {
        #expect(ClaudeChatPanel.canSleepIdleRunner(
            status: .idle,
            isRunning: true,
            hasPendingApprovals: false,
            hasPendingQuestions: false,
            hasPendingDrafts: false
        ))
    }

    @Test func neverSleepsWhenProcessNotRunning() {
        #expect(!ClaudeChatPanel.canSleepIdleRunner(
            status: .idle,
            isRunning: false,
            hasPendingApprovals: false,
            hasPendingQuestions: false,
            hasPendingDrafts: false
        ))
    }

    @Test func neverSleepsMidTurn() {
        #expect(!ClaudeChatPanel.canSleepIdleRunner(
            status: .sending,
            isRunning: true,
            hasPendingApprovals: false,
            hasPendingQuestions: false,
            hasPendingDrafts: false
        ))
    }

    @Test func neverSleepsWhileErrorBannerShowing() {
        #expect(!ClaudeChatPanel.canSleepIdleRunner(
            status: .error("boom"),
            isRunning: true,
            hasPendingApprovals: false,
            hasPendingQuestions: false,
            hasPendingDrafts: false
        ))
    }

    @Test func neverSleepsWithPendingApprovalQuestionOrDraft() {
        #expect(!ClaudeChatPanel.canSleepIdleRunner(
            status: .idle, isRunning: true,
            hasPendingApprovals: true,
            hasPendingQuestions: false,
            hasPendingDrafts: false
        ))
        #expect(!ClaudeChatPanel.canSleepIdleRunner(
            status: .idle, isRunning: true,
            hasPendingApprovals: false,
            hasPendingQuestions: true,
            hasPendingDrafts: false
        ))
        #expect(!ClaudeChatPanel.canSleepIdleRunner(
            status: .idle, isRunning: true,
            hasPendingApprovals: false,
            hasPendingQuestions: false,
            hasPendingDrafts: true
        ))
    }
}
