import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct CommentLifecycleCommandTests {
  @Test(arguments: [false, true])
  func rootPostingAndLifecycleShareTheCommand(json: Bool) throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      let env = TaskCommandTests.fixed
      let posted = try SiltaBinary.run(
        ["comment", "AC-1", "-m", "Review finding."], in: scratch, environment: env)
      try #require(posted.termination == .exit(0))
      let result = try SiltaBinary.run(
        ["comment", "resolve", "AC-1/1", "-m", "Fixed."] + (json ? ["--json"] : []),
        in: scratch, environment: env)
      try #require(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "comment-resolve.\(json ? "json" : "txt")")
      let history = try SiltaBinary.run(
        ["task", "show", "AC-1", "--timeline"], in: scratch, environment: env)
      #expect(
        history.stdout.contains("[resolved by agent:codex:acme]")
          && history.stdout.contains("> Fixed."))
      #expect(!history.stdout.contains("next: silta --ws 'acme' comment"))
      let reopened = try SiltaBinary.run(
        ["comment", "reopen", "task:AC-1/2", "AC-1/1", "--json"], in: scratch, environment: env)
      Golden.forTests().check(reopened.stdout, "comment-reopen.json")
      let data = try TaskStateRegressionTests.data(reopened)
      #expect(data["refs"] as? [String] == ["AC-1/1"])
      #expect(data["created"] as? [String] == [])
      let deleted = try SiltaBinary.run(
        ["comment", "delete", "AC-1/2", "--quiet"], in: scratch, environment: env)
      #expect(deleted.termination == .exit(0) && deleted.stdout.isEmpty)
      let repeated = try SiltaBinary.run(
        ["comment", "delete", "AC-1/2", "--json"], in: scratch, environment: env)
      Golden.forTests().check(repeated.stdout, "comment-delete.json")
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1", "--json"], in: scratch, environment: env)
      #expect(shown.stdout.contains("[deleted]") && !shown.stdout.contains("Fixed."))
      let quiet = try SiltaBinary.run(
        ["comment", "resolve", "AC-1/1", "-m", "Verified.", "--quiet"],
        in: scratch, environment: env)
      #expect(quiet.stdout == "AC-1/3\n")
      let schema = try SiltaBinary.run(["schema", "--json"], in: scratch)
      for command in ["resolve", "reopen", "delete"] {
        #expect(schema.stdout.contains("silta comment " + command))
      }
    }
  }

  @Test(arguments: [false, true])
  func wrongAuthorDeleteKeepsWorkspaceAndNeverAsksHuman(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      _ = try SiltaBinary.run(
        ["comment", "AC-1", "-m", "Private context"], in: scratch,
        environment: TaskCommandTests.fixed)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('other','other','Other','OT');
            UPDATE meta SET value='other' WHERE key='current_workspace';
            """)
      }
      let result = try SiltaBinary.run(
        ["--ws", "acme", "comment", "delete", "AC-1/1"] + (json ? ["--json"] : []),
        in: scratch, environment: ["SILTA_ACTOR": "agent:codex:other"])
      #expect(result.termination == .exit(6))
      Golden.forTests().check(
        json ? result.stdout : result.stderr, "comment-delete-refused.\(json ? "json" : "txt")")
    }
  }

  @Test func promotedDiscussionHasNoMutationHints() throws {
    try withScratchDirectory { scratch in
      _ = try CommentHandoffTests.setup(scratch)
      for args in [
        ["comment", "AC-1", "-m", "Acme finding"],
        ["task", "promote", "AC-1", "--ext", "ado:42", "--approved", "Track Acme"],
      ] {
        let result = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
        try #require(result.termination == .exit(0))
      }
      for flags in [[], ["--timeline"]] {
        let shown = try SiltaBinary.run(
          ["task", "show", "AC-1"] + flags, in: scratch, environment: TaskCommandTests.fixed)
        #expect(shown.stdout.contains("Acme finding"))
        #expect(
          !shown.stdout.contains("comment resolve") && !shown.stdout.contains("comment reopen"))
      }
    }
  }
}

extension CommentLifecycleCommandTests {
  @Test(arguments: ["resolve", "reopen"], [false, true])
  func changedThreadRetryUsesStdin(action: String, stdin: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let env = TaskCommandTests.fixed
      let posted = try SiltaBinary.run(
        ["comment", "AC-1", "-m", "Finding"], in: scratch, environment: env)
      try #require(posted.termination == .exit(0))
      if action == "reopen" {
        let initial = try SiltaBinary.run(
          ["comment", "resolve", "AC-1/1"], in: scratch, environment: env)
        try #require(initial.termination == .exit(0))
      }
      let body = "Pwd=" + "acme-value"
      let args =
        ["--ws", "acme", "comment", action, "AC-1/1", "--allow-secret"]
        + (stdin ? ["-F", "-"] : ["-m", body])
      let binary = shellWord(try SiltaBinary.url().path)
      let file = scratch.appending(path: "explanation.md")
      try Data(body.utf8).write(to: file)
      func run(_ json: Bool) throws -> CLIResult {
        let tokens = args + (json ? ["--json"] : [])
        let command =
          binary + " " + tokens.map(shellWord).joined(separator: " ")
          + " < " + shellWord(file.path)
        return try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", command], in: scratch, environment: env)
      }
      let result = try run(true)
      #expect(result.termination == .exit(3))
      let error = try TaskStateRegressionTests.error(result)
      let next = try #require((error["next"] as? [String])?.first)
      withKnownIssue("#259: thread lifecycle loses stdin on retry") {
        #expect(next.contains(" --allow-secret -F - "))
      }
      guard next.contains(" --allow-secret -F - ") else { return }
      let text = try run(false)
      #expect(text.termination == .exit(3) && text.stderr.contains("ask human: " + next))
      let retry =
        binary
        + String(next.dropFirst("silta".count))
        .replacingOccurrences(of: "<the human's words>", with: "Keep the Acme explanation")
        + " < " + shellWord(file.path)
      let replay = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"), ["-c", retry], in: scratch, environment: env)
      #expect(replay.termination == .exit(0))
      let stored = try store.read {
        try String.fetchOne($0, sql: "SELECT body_md FROM comment WHERE seq=2")
      }
      let audit = try store.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
      #expect(stored == body)
      #expect(audit?.contains("-F <file> --allow-secret") == true)
      #expect(audit?.contains(body) == false)
    }
  }

  @Test(arguments: ["resolve", "reopen"], [false, true])
  func unchangedSecretFlagsDoNotRequireConsent(action: String, placeholder: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try CommentHandoffTests.setup(scratch)
      let env = TaskCommandTests.fixed
      _ = try SiltaBinary.run(["comment", "AC-1", "-m", "Finding"], in: scratch, environment: env)
      if action == "resolve" {
        _ = try SiltaBinary.run(["comment", action, "AC-1/1"], in: scratch, environment: env)
      }
      func snapshot() throws -> [String] {
        try store.read { db in
          try ["task", "comment", "task_event", "approval", "change_log"].flatMap {
            try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid").map(
              String.init(describing:))
          }
        }
      }
      let before = try snapshot()
      let later = env.merging(["SILTA_NOW": "2023-11-14T22:13:21.000Z"]) { $1 }
      let args = [
        "comment", action, "AC-1/1", "--allow-secret", "-m", "Pwd=" + "acme-value", "--json",
      ]
      let result = try SiltaBinary.run(
        args + (placeholder ? ["--approved", "<the human's words>"] : []),
        in: scratch, environment: later)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("\"created\":[]") && !result.stdout.contains("acme-value"))
      #expect(result.stdout.contains("approval_unused") == placeholder)
      #expect(try snapshot() == before)
      let changed = try SiltaBinary.run(
        [
          "comment", action == "resolve" ? "reopen" : "resolve", "AC-1/1", "--allow-secret", "-m",
          "Context", "--json",
        ],
        in: scratch, environment: later)
      #expect(changed.termination == .exit(3) && changed.stdout.contains("human_only"))
      #expect(try snapshot() == before)
    }
  }
}
