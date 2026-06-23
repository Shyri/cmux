import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Chatmux-only: covers decoding of `glab ... -F json` payloads into the
/// fork's GitLab panel models. The mapping (field renames, fallbacks,
/// optimistic-mutation fields, date parsing) is what breaks silently if
/// glab's JSON shape drifts, so each model gets a representative fixture.
@Suite struct GitLabModelDecodingTests {
    // MARK: - Release

    @Test func decodesReleaseWithAssetsAndAuthor() throws {
        let json = """
        [{
          "tag_name":"v1.0","name":"Release 1.0","description":"notes",
          "released_at":"2024-01-15T10:00:00Z","upcoming_release":false,
          "author":{"name":"Alice","username":"alice"},
          "assets":{"count":2,"sources":[{"format":"zip","url":"https://x/src.zip"}],
            "links":[{"name":"binary","direct_asset_url":"https://x/bin","link_type":"package"}]},
          "_links":{"self":"https://gl/release"}
        }]
        """
        let releases = try GitLabRelease.decodeList(from: Data(json.utf8))
        let release = try #require(releases.first)
        #expect(release.tagName == "v1.0")
        #expect(release.name == "Release 1.0")
        #expect(release.webURL == "https://gl/release")
        #expect(release.authorName == "Alice")
        #expect(release.authorUsername == "alice")
        #expect(release.releasedAt != nil)
        #expect(release.sourceCount == 1)
        #expect(release.assetLinks == [
            GitLabReleaseAsset(name: "binary", url: "https://x/bin", linkType: "package")
        ])
    }

    @Test func releaseNameFallsBackToTagWhenBlank() throws {
        let json = #"[{"tag_name":"v2.0","name":"","_links":{"self":"u"}}]"#
        let release = try #require(try GitLabRelease.decodeList(from: Data(json.utf8)).first)
        #expect(release.name == "v2.0")
    }

    // MARK: - Pipeline

    @Test func decodesPipelineAndComputesShortSHA() throws {
        let json = """
        [{"id":123,"iid":5,"status":"success","ref":"main","sha":"abcdef1234567890",
          "web_url":"https://gl/p/123","source":"push","created_at":"2024-01-15T10:00:00Z"}]
        """
        let pipeline = try #require(try GitLabPipeline.decodeList(from: Data(json.utf8)).first)
        #expect(pipeline.id == 123)
        #expect(pipeline.iid == 5)
        #expect(pipeline.status == "success")
        #expect(pipeline.ref == "main")
        #expect(pipeline.sha == "abcdef1234567890")
        #expect(pipeline.shortSHA == "abcdef12")
        #expect(pipeline.source == "push")
        #expect(pipeline.createdAt != nil)
    }

    @Test func pipelineMissingStatusBecomesEmptyString() throws {
        let json = #"[{"id":1,"sha":"x"}]"#
        let pipeline = try #require(try GitLabPipeline.decodeList(from: Data(json.utf8)).first)
        #expect(pipeline.status == "")
        #expect(pipeline.ref == "")
    }

    // MARK: - Merge Request

    @Test func decodesMergeRequestWithReviewersAndAssignees() throws {
        let json = """
        [{"id":1,"iid":42,"project_id":7,"title":"Add feature","state":"opened",
          "author":{"name":"Bob","username":"bob"},"web_url":"https://gl/mr/42",
          "source_branch":"feat","target_branch":"main","labels":["bug","p1"],"draft":true,
          "reviewers":[{"name":"Rev","username":"rev"}],"assignees":[{"name":"Asg","username":"asg"}],
          "user_notes_count":3,"merge_status":"can_be_merged","has_conflicts":false}]
        """
        let mr = try #require(try GitLabMergeRequest.decodeList(from: Data(json.utf8)).first)
        #expect(mr.iid == 42)
        #expect(mr.projectId == 7)
        #expect(mr.title == "Add feature")
        #expect(mr.authorUsername == "bob")
        #expect(mr.sourceBranch == "feat")
        #expect(mr.targetBranch == "main")
        #expect(mr.labels == ["bug", "p1"])
        #expect(mr.isDraft == true)
        #expect(mr.reviewers == [GitLabReviewer(name: "Rev", username: "rev")])
        #expect(mr.assignees == [GitLabReviewer(name: "Asg", username: "asg")])
        #expect(mr.userNotesCount == 3)
        #expect(mr.mergeStatus == "can_be_merged")
        #expect(mr.hasConflicts == false)
        #expect(mr.approval == nil)
    }

    @Test func mergeRequestDefaultsMissingOptionalFields() throws {
        let json = #"[{"id":1,"iid":2,"title":"t","state":"opened"}]"#
        let mr = try #require(try GitLabMergeRequest.decodeList(from: Data(json.utf8)).first)
        #expect(mr.projectId == 0)
        #expect(mr.labels.isEmpty)
        #expect(mr.isDraft == false)
        #expect(mr.reviewers.isEmpty)
        #expect(mr.assignees.isEmpty)
    }

    // MARK: - Issue

    @Test func decodesIssueWithMilestoneAndFiltersBlankAssignees() throws {
        let json = """
        [{"id":10,"iid":3,"project_id":7,"title":"Bug report","state":"opened",
          "author":{"name":"Carol","username":"carol"},"web_url":"https://gl/i/3","labels":["bug"],
          "milestone":{"id":2,"title":"v1","state":"active","due_date":"2024-03-01"},
          "assignees":[{"name":"Dave","username":"dave"},{"name":"","username":""}],
          "user_notes_count":5,"created_at":"2024-01-01T00:00:00Z"}]
        """
        let issue = try #require(try GitLabIssue.decodeList(from: Data(json.utf8)).first)
        #expect(issue.iid == 3)
        #expect(issue.title == "Bug report")
        #expect(issue.labels == ["bug"])
        #expect(issue.milestone?.title == "v1")
        #expect(issue.milestone?.dueDate != nil)
        // The blank assignee is dropped; only the real one survives.
        #expect(issue.assignees == [GitLabAssignee(name: "Dave", username: "dave")])
        #expect(issue.userNotesCount == 5)
        #expect(issue.relatedOpenMRsCount == nil)
    }

    @Test func issueWithoutMilestoneTitleHasNilMilestone() throws {
        let json = #"[{"id":1,"iid":1,"title":"t","milestone":{"id":9,"title":""}}]"#
        let issue = try #require(try GitLabIssue.decodeList(from: Data(json.utf8)).first)
        #expect(issue.milestone == nil)
        // Missing state defaults to "opened".
        #expect(issue.state == "opened")
    }

    // MARK: - Framing

    @Test func emptyArrayDecodesToEmpty() throws {
        #expect(try GitLabIssue.decodeList(from: Data("[]".utf8)).isEmpty)
        #expect(try GitLabMergeRequest.decodeList(from: Data("[]".utf8)).isEmpty)
        #expect(try GitLabPipeline.decodeList(from: Data("[]".utf8)).isEmpty)
        #expect(try GitLabRelease.decodeList(from: Data("[]".utf8)).isEmpty)
    }

    @Test func nonArrayPayloadThrows() {
        #expect(throws: (any Error).self) {
            _ = try GitLabIssue.decodeList(from: Data("{}".utf8))
        }
    }
}
