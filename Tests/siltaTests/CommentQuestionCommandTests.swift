import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct CommentQuestionCommandTests {
  @Test(arguments: [false, true])
  func threeActorsAskAnswerAcceptAndReopen(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      let asker = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      let answerer = asker.merging(["SILTA_ACTOR": "agent:codex:answerer"]) { $1 }
      let third = asker.merging(["SILTA_ACTOR": "agent:claude:third"]) { $1 }
      func run(_ args: [String], _ actor: [String: String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      let question = try run(
        ["comment", "AC-1", "--kind", "question", "-m", "Which API?", "--json"], asker)
      try #require(question.termination == .exit(0))
      Golden.forTests().check(question.stdout, "comment-question.json")
      let answer = try run(
        [
          "comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "Use v2.",
          "--from", "note:notes/acme.md", "--to", "agent:codex:acme", "--json",
        ], answerer)
      try #require(answer.termination == .exit(0))
      try Self.checkAnswer(answer)
      let wrong = try run(["comment", "accept", "AC-1/2", "--json"], answerer)
      #expect(wrong.termination == .exit(6))
      Golden.forTests().check(wrong.stdout, "comment-accept-refused.json")
      let answered = try run(["task", "show", "AC-1"], third)
      #expect(answered.stdout.contains("[unresolved]"))
      #expect(!answered.stdout.contains("next:"))
      let accepted = try run(
        ["comment", "accept", "AC-1/2"] + (json ? ["--json"] : []), asker)
      try #require(accepted.termination == .exit(0))
      Golden.forTests().check(accepted.stdout, "comment-accept.\(json ? "json" : "txt")")
      let timeline = try run(["task", "show", "AC-1", "--timeline"], third)
      #expect(timeline.stdout.contains("[accepted]"))
      #expect(timeline.stdout.contains("resolved by agent:codex:acme"))
      #expect(timeline.stdout.contains("accepted AC-1/2") && !timeline.stdout.contains("next:"))
      let repeatAccept = try run(["comment", "accept", "AC-1/2"], asker)
      #expect(repeatAccept.stdout == "AC-1/2 already accepted\n")
      let reopened = try run(["comment", "reopen", "AC-1/2", "--quiet"], third)
      #expect(reopened.termination == .exit(0) && reopened.stdout.isEmpty)
      let reply = try run(
        ["comment", "AC-1", "--reply-to", "AC-1/2", "-m", "Thanks @me.", "--json"], third)
      #expect(reply.termination == .exit(0))
      #expect(try TaskStateRegressionTests.data(reply)["reply_to"] as? String == "AC-1/1")
      #expect(try TaskStateRegressionTests.data(reply)["mentions"] as? [String] == ["human:acme"])
      try Self.checkPrivateLogs(scratch)
    }
  }

  static func checkAnswer(_ answer: CLIResult) throws {
    let value = try TaskStateRegressionTests.data(answer)
    #expect(value["reply_to"] as? String == "AC-1/1")
    #expect(value["from"] as? String == "note:notes/acme.md")
    #expect(value["mentions"] as? [String] == ["agent:codex:acme"])
  }

  static func checkPrivateLogs(_ scratch: URL) throws {
    let log = try String(
      contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
    for content in ["Which API?", "Use v2.", "notes/acme.md", "Thanks @me."] {
      #expect(!log.contains(content))
    }
  }

  @Test(arguments: ["@me-other", "@me:other", "@agent:Codex:s", "@human:acme/other"])
  func malformedQuestionMentionsNeverDefaultToHuman(mention: String) throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let result = try SiltaBinary.run(
        ["comment", "AC-1", "--kind", "question", "-m", "Ask \(mention)", "--json"],
        in: scratch, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1) && result.stdout.contains("\"invalid\""))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM comment") } == 0)
    }
  }
}
