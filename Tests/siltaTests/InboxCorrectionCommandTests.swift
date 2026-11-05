import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct InboxCorrectionCommandTests {
  static let scope =
    "Scope: discussion only; proposals, blockers and promoted attention are not included."

  @Test func selfAcceptanceRefusalHasReadOnlyRecovery() throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let actor = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      _ = try run([
        "comment", "AC-1", "--kind", "question", "--to", "agent:codex:acme", "-m", "Which API?",
      ])
      try store.write { try $0.database.execute(sql: "UPDATE comment SET actor='human:acme'") }
      _ = try run(["comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "v2"])
      let refused = try run(["comment", "accept", "AC-1/2", "--json"])
      #expect(refused.termination == .exit(6))
      Golden.forTests().check(refused.stdout, "inbox-self-accept-refused.json")
      #expect(
        try run(["--ws", "acme", "task", "show", "AC-1", "--timeline"]).termination == .exit(0))
      let own = try TaskStateRegressionTests.data(run(["inbox", "--json"]))
      #expect((own["items"] as? [Any])?.isEmpty == true)
      let human = try TaskStateRegressionTests.data(run(["inbox", "--for", "me", "--json"]))
      let pending = try #require(human["items"] as? [[String: Any]])
      #expect(
        pending.first?["next"] as? [String] == ["silta --ws 'acme' task show 'AC-1' --timeline"])
    }
  }

  @Test func relayGuidanceAndScopeAreExplicit() throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      let actor = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      _ = try run(["task", "add", "Acme proposal"])
      let empty = try run(["inbox", "--for", "me"])
      let raw = try TaskStateRegressionTests.data(run(["inbox", "--for", "me", "--json"]))
      #expect(empty.stdout.contains(Self.scope))
      #expect(raw["scope"] as? String == "discussion")
      _ = try run(["comment", "AC-1", "--kind", "question", "-m", "Which API?"])
      _ = try run([
        "comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "Human said v2.",
      ])
      let inbox = try run(["inbox", "--for", "me", "--json"])
      let items = try #require(
        try TaskStateRegressionTests.data(inbox)["items"] as? [[String: Any]])
      #expect(items.first?["relayed_by"] as? [String] == ["agent:codex:acme"])
      let next = items.first?["next"] as? [String] ?? []
      #expect(next.contains { $0.hasPrefix("ask human:") })
      #expect(!next.contains { $0.contains("--kind answer") })
    }
  }

  @Test func schemaAllowsGroupedItemsAndNamesDiscussionPosts() throws {
    try withScratchDirectory { scratch in
      let output = try SiltaBinary.run(["schema", "inbox", "--json"], in: scratch)
      let data = try TaskStateRegressionTests.data(output)
      let commands = try #require(data["commands"] as? [[String: Any]])
      let shape = try #require(commands.first?["data"] as? [String: Any])
      let object = try #require(shape["object"] as? [String: Any])
      let items = try #require(object["items"] as? [String: Any])
      let array = try #require(items["array"] as? [String: Any])
      let fields = try #require(array["object"] as? [String: Any])
      #expect(
        ShapeCheck.violations(of: ["kind": "blocked", "next": [String]()], against: array).isEmpty
      )
      for key in ["ref", "task", "author", "body", "created_at"] {
        #expect((fields[key] as? [String: Any])?["optional"] as? String == "string")
      }
      #expect(fields["post_kind"] != nil && fields["reply_to"] != nil)
    }
  }

  @Test func allKindsCappedAndExactlyTwelveAreFramed() throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      let owner = TaskCommandTests.fixed
      let foreign = owner.merging([
        "SILTA_ACTOR": "agent:claude:other", "SILTA_NOW": "2023-11-14T22:13:21.000Z",
      ]) { $1 }
      func run(_ args: [String], _ actor: [String: String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      _ = try run(
        ["comment", "AC-1", "--kind", "question", "--to", "agent:claude:other", "-m", "First?"],
        owner)
      _ = try run(
        ["comment", "AC-1", "--kind", "question", "--to", "agent:codex:acme", "-m", "Second?"],
        foreign)
      _ = try run(
        ["comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "v2"], foreign)
      let file = scratch.appending(path: "decision.md")
      try "Decision\n\n".write(to: file, atomically: true, encoding: .utf8)
      _ = try run(["comment", "AC-1", "--kind", "decision", "-F", file.path], foreign)
      let text = try run(["inbox"], owner)
      let raw = try TaskStateRegressionTests.data(run(["inbox", "--json"], owner))
      let items = try #require(raw["items"] as? [[String: Any]])
      Golden.forTests().check(text.stdout, "inbox-all-kinds.txt")
      #expect(items.map { $0["kind"] as? String } == ["question", "answer", "discussion"])
      #expect(items[1]["reply_to"] as? String == "AC-1/1")
      #expect(items[2]["post_kind"] as? String == "decision")
      #expect(text.stdout.contains("clears on the claimer's next write to AC-1"))
      for _ in 0..<9 { _ = try run(["comment", "AC-1", "-m", "Context"], foreign) }
      let twelve = try TaskStateRegressionTests.data(run(["inbox", "--json"], owner))
      #expect((twelve["items"] as? [Any])?.count == 12)
      #expect(twelve["remaining"] as? Int == 0 && twelve["more"] == nil)
      _ = try run(["comment", "AC-1", "-m", "Omitted"], foreign)
      let capped = try run(["inbox"], owner)
      Golden.forTests().check(capped.stdout, "inbox-capped.txt")
    }
  }
}
