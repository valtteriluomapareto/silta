import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct InboxCommandTests {
  @Test(arguments: [false, true])
  func questionRelayAndEveryNextCommand(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      let actor = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      _ = try run(["comment", "AC-1", "--kind", "question", "-m", "Which API?"])
      let args = ["--ws", "acme", "inbox", "--for", "me"]
      let result = try run(args + (json ? ["--json"] : []))
      try #require(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "inbox.\(json ? "json" : "txt")")
      let file = scratch.appending(path: "answer.md")
      try "Human said v2.".write(to: file, atomically: true, encoding: .utf8)
      let answer = try run([
        "--ws", "acme", "comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1",
        "-F", file.path,
      ])
      #expect(answer.termination == .exit(0))
      #expect(try run(args).stdout.contains("AC-1/1 question"))
      let own = try run(["--ws", "acme", "inbox", "--json"])
      let data = try TaskStateRegressionTests.data(own)
      let items = try #require(data["items"] as? [[String: Any]])
      #expect(items.first?["kind"] as? String == "answer")
      #expect(items.first?["next"] as? [String] == ["silta --ws 'acme' comment accept 'AC-1/2'"])
      #expect(try run(["--ws", "acme", "comment", "accept", "AC-1/2"]).termination == .exit(0))
      #expect(try run(args).stdout == "No discussion attention for human:acme.\n")
      _ = try run(["comment", "reopen", "AC-1/1"])
      #expect(
        try run(["--ws", "acme", "comment", "resolve", "AC-1/1", "-m", "Relayed v2 in chat."])
          .termination == .exit(0))
      #expect(try run(args + ["--all"]).stdout == "No discussion attention for human:acme.\n")
      let help = try run(["comment", "--help"])
      #expect(help.stdout.contains("never supplies approval words"))
    }
  }

  @Test func invalidTargetRecoveryAndSchema() throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      for target in ["agent:codex", "human:", "@me"] {
        let result = try SiltaBinary.run(
          ["inbox", "--for", target, "--json"], in: scratch, environment: TaskCommandTests.fixed)
        #expect(result.termination == .exit(1))
        #expect(
          result.stdout.contains("\"invalid\"") && result.stdout.contains("silta inbox --help"))
        Golden.forTests().check(result.stdout, "inbox-invalid.json")
      }
      let help = try SiltaBinary.run(["inbox", "--help"], in: scratch)
      #expect(help.termination == .exit(0) && help.stdout.contains("Discussion attention only"))
      let schema = try SiltaBinary.run(["schema", "inbox", "--json"], in: scratch)
      #expect(schema.termination == .exit(0) && schema.stdout.contains("remaining"))
    }
  }

  @Test func foreignRelayResolutionAndClaimedDiscussionNext() throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      let holder = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      let other = holder.merging([
        "SILTA_ACTOR": "agent:claude:other", "SILTA_NOW": "2023-11-14T22:13:21.000Z",
      ]) { $1 }
      func run(_ args: [String], _ actor: [String: String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      _ = try run(
        ["comment", "AC-1", "--kind", "question", "--to", "agent:codex:acme", "-m", "Which API?"],
        holder)
      _ = try run(
        [
          "comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m",
          "Human confirmed v2.",
        ], other)
      let foreign = try run(
        ["--ws", "acme", "inbox", "--for", "agent:codex:acme", "--json"], other)
      let items = try #require(
        try TaskStateRegressionTests.data(foreign)["items"] as? [[String: Any]])
      #expect(items.map { $0["ref"] as? String } == ["AC-1/1", "AC-1/2"])
      #expect(
        items.last?["next"] as? [String] == [
          "silta --ws 'acme' comment resolve 'AC-1/1' -m <reason>"
        ])
      _ = try run(
        ["--ws", "acme", "comment", "resolve", "AC-1/1", "-m", "Human confirmed v2 in chat."], other
      )
      let discussion = try run(["--ws", "acme", "inbox", "--json"], holder)
      let posts = try #require(
        try TaskStateRegressionTests.data(discussion)["items"] as? [[String: Any]])
      #expect(posts.last?["next"] as? [String] == ["silta --ws 'acme' task show 'AC-1' --timeline"])
      #expect(
        try run(["--ws", "acme", "task", "show", "AC-1", "--timeline"], holder).termination
          == .exit(0))
    }
  }
}
