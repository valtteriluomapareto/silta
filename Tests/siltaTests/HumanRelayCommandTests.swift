import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct HumanRelayCommandTests {
  private static let resolve =
    "silta --ws 'acme' comment resolve 'AC-1/1' -m \"<confirmed answer>\""
  private static let confirm =
    "Does AC-1/2 relay your confirmed answer to AC-1/1? Only if yes: " + resolve
  private static let read = "silta --ws 'acme' task show 'AC-1' --timeline"
  private static let body = "Acme human said v2."
  private static let answerRow = "AC-1/2 answer to AC-1/1 on AC-1 by agent:codex:acme"

  @Test(arguments: ["me", "storedHuman", "mixed", "askerIsAddressed"])
  func ownAnswerNeedsConfirmationForAHumanQuestion(target: String) throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let actor = TaskCommandTests.fixed.merging(["USER": "acme"]) { $1 }
      let selfAddressed = target == "askerIsAddressed"
      let recipient = target == "me" ? "me" : "human:acme-owner"
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: actor)
      }
      let question = try run(
        ["comment", "AC-1", "--kind", "question", "-m", "Which Acme API?"]
          + Self.targets(recipient, mode: target))
      try #require(question.termination == .exit(0))
      let answer = try run([
        "comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", Self.body,
      ])
      try #require(answer.termination == .exit(0))

      if !selfAddressed {
        let human = try Self.nextFor(
          "AC-1/1", in: run(["inbox", "--for", recipient, "--json"]))
        #expect(human == ["ask human: " + Self.confirm, Self.read])
      }
      let own = try Self.nextFor("AC-1/2", in: run(["inbox", "--json"]))
      let text = try run(["inbox"])
      let refused = try run(["comment", "accept", "AC-1/2", "--json"])
      let error = try GuideContractTests.object(refused.stdout)["error"] as? [String: Any]
      let prefix = target == "me" ? "ask human: " : "ask human: Ask human:acme-owner. "
      let expected = selfAddressed ? [Self.read] : [prefix + Self.confirm, Self.read]
      let wasResolved = try Self.resolved(store)
      let wasAccepted = try Self.accepted(store)
      let next = error?["next"] as? [String] ?? []

      #expect(own == expected)
      #expect(
        text.stdout.contains(Self.answerRow + "\n> " + Self.body + "\nnext: " + expected[0]))
      #expect(refused.termination == .exit(6))
      #expect(error?["code"] as? String == "conflict")
      #expect(error?["next_by"] as? String == (selfAddressed ? "agent" : "human"))
      #expect(next == (selfAddressed ? [Self.read] : [Self.resolve]))
      #expect(wasResolved == nil)
      #expect(!wasAccepted)

      guard !selfAddressed else { return }
      try Self.replayConfirmation(next, as: actor, in: scratch)
      #expect(try Self.resolved(store) == "agent:codex:acme")
      #expect(try !Self.accepted(store))
      let final = try TaskStateCommandTests.data(run(["inbox", "--json"]))
      let finalItems = try #require(final["items"] as? [[String: Any]])
      #expect(!finalItems.contains { $0["kind"] as? String == "answer" })
    }
  }

  @Test func anAgentOnlyQuestionCanStillAcceptItsAskersOwnAnswer() throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let actor = TaskCommandTests.fixed
      let runs: [[String]] = [
        ["comment", "AC-1", "--kind", "question", "--to", "agent:claude:other", "-m", "Acme?"],
        ["comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "Use API v2."],
        ["comment", "accept", "AC-1/2"],
      ]
      for args in runs {
        #expect(try SiltaBinary.run(args, in: scratch, environment: actor).termination == .exit(0))
      }
      #expect(try Self.accepted(store))
    }
  }

  private static func targets(_ recipient: String, mode: String) -> [String] {
    var result = ["--to", recipient]
    if mode == "mixed" { result += ["--to", "agent:claude:acme-reviewer"] }
    if mode == "askerIsAddressed" { result += ["--to", "agent:codex:acme"] }
    return result
  }

  private static func replayConfirmation(
    _ next: [String], as actor: [String: String], in scratch: URL
  ) throws {
    let instruction = try #require(next.first)
    let confirmed = instruction.replacingOccurrences(
      of: "\"<confirmed answer>\"", with: shellWord("Acme confirmed v2."))
    let binary = shellWord(try SiltaBinary.url().path)
    let replay = try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"), ["-c", binary + confirmed.dropFirst("silta".count)],
      in: scratch, environment: actor)
    #expect(replay.termination == .exit(0))
  }

  private static func nextFor(_ ref: String, in result: CLIResult) throws -> [String] {
    let data = try TaskStateCommandTests.data(result)
    let items = try #require(data["items"] as? [[String: Any]])
    return try #require(items.first { $0["ref"] as? String == ref }?["next"] as? [String])
  }

  private static func resolved(_ store: DatabaseStore) throws -> String? {
    try store.read { try String.fetchOne($0, sql: "SELECT resolved_by FROM comment WHERE seq=1") }
  }

  private static func accepted(_ store: DatabaseStore) throws -> Bool {
    try store.read {
      try Bool.fetchOne($0, sql: "SELECT accepted FROM comment WHERE seq=2") == true
    }
  }
}
