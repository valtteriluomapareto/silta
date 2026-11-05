import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct CommentRecoverySafetyTests {
  static let alpha = TaskCommandTests.fixed.merging([
    "SILTA_ACTOR": "agent:codex:alpha", "USER": "acme",
  ]) { $1 }
  static let beta = alpha.merging(["SILTA_ACTOR": "agent:claude:beta"]) { $1 }

  static func run(_ args: [String], in home: URL, actor: [String: String] = alpha) throws
    -> CLIResult
  {
    try SiltaBinary.run(args, in: home, environment: actor)
  }

  static func follow(_ command: String, in home: URL) throws -> CLIResult {
    // Fixture refs and workspace have no spaces; fill the only old recovery placeholder.
    let words = command.replacingOccurrences(of: "<why>", with: "Acme")
      .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
      .split(whereSeparator: \.isWhitespace).map(String.init)
    try #require(words.first == "silta")
    return try run(Array(words.dropFirst()), in: home)
  }

  static func snapshot(_ store: DatabaseStore) throws -> [String] {
    try store.read { db in
      try [
        "task", "comment", "task_event", "change_log", "approval", "link", "meta", "seq_counter",
      ]
      .flatMap { table in
        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(
          String.init(describing:))
      }
    }
  }

  static func questionAfterHandoff(_ home: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(home)
    for args in [
      ["task", "add", "Acme", "--start"],
      ["comment", "AC-1", "--kind", "question", "--to", "agent:codex:alpha", "-m", "Which API?"],
      ["comment", "AC-1", "--kind", "answer", "--reply-to", "AC-1/1", "-m", "v2"],
      ["comment", "AC-1", "--reply-to", "AC-1/1", "-m", "Human context"],
    ] {
      try #require(try run(args, in: home).termination == .exit(0))
    }
    try store.write {
      try $0.database.execute(sql: "UPDATE comment SET actor='human:acme' WHERE seq IN (1,3)")
    }
    try #require(
      try run(["comment", "AC-1", "--kind", "handoff", "-m", "Continue"], in: home).termination
        == .exit(0))
    try #require(try run(["task", "start", "AC-1"], in: home, actor: beta).termination == .exit(0))
    return store
  }

  @Test(arguments: [
    "accept", "delete-root", "delete-reply", "empty-resolve", "empty-resolve-reply",
    "empty-batch-first", "empty-batch-last",
  ])
  func refusalNextCannotCloseSomeoneElsesQuestion(mode: String) throws {
    try withScratchDirectory { home in
      let store = try Self.questionAfterHandoff(home)
      let batch = mode.hasPrefix("empty-batch")
      if batch {
        try #require(
          try Self.run(["task", "add", "Other", "--start"], in: home).termination == .exit(0))
        try #require(
          try Self.run(["comment", "AC-2", "-m", "Own context"], in: home).termination == .exit(0))
      }
      let refs = mode == "empty-batch-first" ? ["AC-1/1", "AC-2/1"] : ["AC-2/1", "AC-1/1"]
      let args: [String]
      switch mode {
      case "accept": args = ["comment", "accept", "AC-1/2"]
      case "delete-root": args = ["comment", "delete", "AC-1/1"]
      case "delete-reply": args = ["comment", "delete", "AC-1/3"]
      default:
        args =
          ["comment", "resolve"]
          + (batch ? refs : [mode == "empty-resolve-reply" ? "AC-1/2" : "AC-1/1"]) + ["-m", ""]
      }
      let pendingArgs = ["--ws", "acme", "inbox", "--for", "human:acme", "--json"]
      let before = try Self.run(pendingArgs, in: home).stdout
      try #require(before.contains("AC-1/2"))
      let stable = try Self.snapshot(store)
      let refusal = try Self.run(["--ws", "acme"] + args + ["--json"], in: home)
      #expect(refusal.termination == .exit(mode.hasPrefix("empty") ? 1 : 6))
      #expect(try Self.snapshot(store) == stable)
      let envelope = try #require(
        try JSONSerialization.jsonObject(with: Data(refusal.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      let next = try #require(error["next"] as? [String])
      for command in next {
        #expect(try Self.follow(command, in: home).termination == .exit(0))
      }
      let after = try Self.run(pendingArgs, in: home).stdout
      let afterRows = try Self.snapshot(store)
      let expected =
        ["silta --ws 'acme' task show 'AC-1' --timeline"]
        + (batch ? ["silta --ws 'acme' task show 'AC-2' --timeline"] : [])
      withKnownIssue("SI-37/53: refusal recovery closes another actor's question") {
        #expect(next == expected)
        #expect(after == before)
        #expect(afterRows == stable)
        #expect(!(error["message"] as? String ?? "").contains("omit -m"))
      }
    }
  }

  @Test func foreignInboxNamesTheClaimerWhoseWriteClearsAttention() throws {
    try withScratchDirectory { home in
      let store = try TaskCommandTests.setup(home)
      try #require(
        try Self.run(["task", "add", "Acme", "--start"], in: home, actor: Self.beta).termination
          == .exit(0))
      let later = Self.alpha.merging(["SILTA_NOW": "2023-11-14T22:13:21.000Z"]) { $1 }
      _ = try Self.run(["comment", "AC-1", "-m", "Finding"], in: home, actor: later)
      let args = ["--ws", "acme", "inbox", "--for", "agent:claude:beta"]
      let text = try Self.run(args, in: home).stdout
      let boundary = try store.read { try String.fetchOne($0, sql: "SELECT claimed_at FROM task") }
      _ = try Self.run(["comment", "AC-1", "-m", "Foreign write"], in: home, actor: later)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT claimed_at FROM task") } == boundary)
      let pending = try TaskStateRegressionTests.data(Self.run(args + ["--json"], in: home))
      #expect((pending["items"] as? [Any])?.count == 2)
      let holder = Self.beta.merging(["SILTA_NOW": "2023-11-14T22:13:22.000Z"]) { $1 }
      _ = try Self.run(["comment", "AC-1", "-m", "Addressed"], in: home, actor: holder)
      let cleared = try TaskStateRegressionTests.data(Self.run(args + ["--json"], in: home))
      #expect((cleared["items"] as? [Any])?.isEmpty == true)
      withKnownIssue("SI-37/19 and /54: foreign-target text names the caller's write") {
        #expect(text.contains("clears on the claimer's next write to AC-1"))
        #expect(!text.contains("clears on your next write"))
      }
    }
  }

  @Test(arguments: ["own-question", "own-comment", "foreign-comment"])
  func explicitSafeResolveRetriesArePreserved(mode: String) throws {
    try withScratchDirectory { home in
      let store = try TaskCommandTests.setup(home)
      _ = try Self.run(["task", "add", "Acme", "--start"], in: home)
      _ = try Self.run(
        [
          "comment", "AC-1", "--kind", mode == "own-question" ? "question" : "comment", "-m",
          "Context",
        ], in: home)
      if mode == "foreign-comment" {
        try store.write { try $0.database.execute(sql: "UPDATE comment SET actor='human:acme'") }
      }
      let refusal = try Self.run(["comment", "resolve", "AC-1/1", "-m", "", "--json"], in: home)
      let envelope = try #require(
        try JSONSerialization.jsonObject(with: Data(refusal.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      let next = try #require(error["next"] as? [String])
      #expect(next == ["silta --ws 'acme' comment resolve 'AC-1/1'"])
      #expect(try Self.follow(try #require(next.first), in: home).termination == .exit(0))
    }
  }

  @Test func explicitConfirmedResolveRemainsAvailable() throws {
    try withScratchDirectory { home in
      _ = try Self.questionAfterHandoff(home)
      let result = try Self.run(
        [
          "comment", "resolve", "AC-1/1", "-m", "Human confirmed v2 in chat.",
        ], in: home)
      #expect(result.termination == .exit(0))
      let pending = try TaskStateRegressionTests.data(
        Self.run(
          [
            "inbox", "--for", "human:acme", "--json",
          ], in: home))
      #expect((pending["items"] as? [Any])?.isEmpty == true)
    }
  }
}
