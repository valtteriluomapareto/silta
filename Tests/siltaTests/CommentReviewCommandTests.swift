import Foundation
import SiltaTestSupport
import Testing

struct CommentReviewCommandTests {
  static func run(_ home: URL, _ args: [String], actor: String = "agent:codex:acme") throws
    -> CLIResult
  {
    try SiltaBinary.run(
      args, in: home, environment: TaskCommandTests.fixed.merging(["SILTA_ACTOR": actor]) { $1 })
  }

  @Test func resolutionAttributionIsVisibleOnRootsAndReplies() throws {
    try withScratchDirectory { home in
      _ = try CommentHandoffTests.setup(home)
      _ = try Self.run(home, ["comment", "AC-1", "-m", "Finding"], actor: "agent:claude:poster")
      _ = try Self.run(home, ["comment", "resolve", "AC-1/1", "-m", "Fixed"])
      let raw = try Self.run(home, ["task", "show", "AC-1", "--timeline", "--json"])
      let data = try TaskStateRegressionTests.data(raw)
      let comments = try #require(data["comments"] as? [[String: Any]])
      #expect(
        comments.count == 2
          && comments.allSatisfy { $0["resolved_by"] as? String == "agent:codex:acme" })
      let text = try Self.run(home, ["task", "show", "AC-1", "--timeline"])
      #expect(text.stdout.contains("[resolved by agent:codex:acme]"))
      _ = try Self.run(home, ["comment", "reopen", "AC-1/1"], actor: "agent:claude:coordinator")
      let reopened = try Self.run(home, ["task", "show", "AC-1", "--json"])
      #expect(!reopened.stdout.contains("resolved_by"))
    }
  }

  @Test func deletingAReleasedHandoffKeepsOnlyTheResumeNext() throws {
    try withScratchDirectory { home in
      _ = try CommentHandoffTests.setup(home)
      _ = try Self.run(home, ["comment", "AC-1", "-m", "Finding"])
      _ = try Self.run(home, ["comment", "AC-1", "--kind", "handoff", "-m", "Stopped"])
      let before = try Self.run(home, ["task", "show", "AC-1"])
      #expect(
        !before.stdout.contains("comment resolve") && !before.stdout.contains("comment reopen"))
      #expect(before.stdout.components(separatedBy: "next:").count == 2)
      _ = try Self.run(home, ["comment", "delete", "AC-1/2"])
      let raw = try Self.run(home, ["task", "show", "AC-1", "--json"])
      #expect(try TaskStateRegressionTests.data(raw)["handed_off"] == nil)
      let shown = try Self.run(home, ["task", "show", "AC-1"])
      #expect(!shown.stdout.contains("handed off AC-1/2"))
      #expect(shown.stdout.contains("Unclaimed; next: silta --ws 'acme' task start 'AC-1'"))
      #expect(shown.stdout.components(separatedBy: "next:").count == 2)
    }
  }

  @Test func textReceiptsNameExplanationsAndUnchangedState() throws {
    try withScratchDirectory { home in
      _ = try CommentHandoffTests.setup(home)
      _ = try Self.run(home, ["comment", "AC-1", "-m", "Finding"])
      let changed = try Self.run(home, ["comment", "resolve", "AC-1/1", "-m", "Fixed"])
      #expect(changed.stdout == "AC-1/1 resolved\nexplanations: AC-1/2\n")
      let noop = try Self.run(home, ["comment", "resolve", "AC-1/1"])
      #expect(noop.stdout == "AC-1/1 already resolved\n")
      _ = try Self.run(home, ["comment", "reopen", "AC-1/1"])
      let open = try Self.run(home, ["comment", "reopen", "AC-1/1"])
      #expect(open.stdout == "AC-1/1 already open\n")
    }
  }

  @Test(arguments: ["resolve", "reopen"])
  func explanationErrorsGiveSpecificRecovery(action: String) throws {
    try withScratchDirectory { home in
      _ = try CommentHandoffTests.setup(home)
      _ = try Self.run(home, ["comment", "AC-1", "-m", "Finding"])
      if action == "reopen" { _ = try Self.run(home, ["comment", "resolve", "AC-1/1"]) }
      let absent = try Self.run(home, ["comment", action, "AC-1/1", "--allow-secret", "--json"])
      Golden.forTests().check(absent.stdout, "comment-explanation-required-\(action).json")
      let empty = try Self.run(home, ["comment", action, "AC-1/1", "-m", "", "--json"])
      Golden.forTests().check(empty.stdout, "comment-explanation-empty-\(action).json")
      #expect(empty.stdout.contains("silta --ws 'acme' comment " + action + " 'AC-1/1'"))
      #expect(!empty.stdout.contains("<text>"))
    }
  }

  @Test func wrongAuthorRecoveryNamesActorsAndTheRoot() throws {
    try withScratchDirectory { home in
      _ = try CommentHandoffTests.setup(home)
      _ = try Self.run(home, ["comment", "AC-1", "-m", "Finding"])
      _ = try Self.run(home, ["comment", "resolve", "AC-1/1", "-m", "Reply"])
      let result = try Self.run(
        home, ["comment", "delete", "AC-1/2", "--json"], actor: "agent:codex:other")
      #expect(
        result.stdout.contains("author agent:codex:acme")
          && result.stdout.contains("current actor is agent:codex:other"))
      #expect(!result.stdout.contains("comment resolve"))
      #expect(result.stdout.contains("silta --ws 'acme' task show 'AC-1' --timeline"))
    }
  }

  @Test func lifecycleHelpExplainsReplyAndDeleteTargets() throws {
    try withScratchDirectory { home in
      for action in ["resolve", "reopen"] {
        let help = try Self.run(home, ["comment", action, "--help"])
        let words = help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(words.contains("one reply per changed thread"))
      }
      let help = try Self.run(home, ["comment", "delete", "--help"])
      #expect(help.stdout.contains("root or reply"))
    }
  }
}
