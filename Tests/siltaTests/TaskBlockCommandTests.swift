import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockCommandTests {
  static let environment = [
    "SILTA_ACTOR": "agent:codex:acme",
    "SILTA_NOW": "2023-11-14T22:13:20.000Z",
  ]

  @Test(arguments: [false, true]) func blockRefusesStartAndUnblocksBatch(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          args + ["--deterministic"] + (json ? ["--json"] : []),
          in: scratch, environment: Self.environment)
      }
      for title in ["Acme first", "Acme second"] {
        #expect(try run(["task", "add", title, "--start"]).termination == .exit(0))
      }
      let blocked = try run(["task", "block", "AC-1", "--on", "ext:acme", "-m", "Acme decision"])
      #expect(blocked.termination == .exit(0))
      Golden.forTests().check(blocked.stdout, "task-block" + (json ? ".json" : ".txt"))
      let start = try run(["task", "start", "AC-1"])
      #expect(start.termination == .exit(6))
      Golden.forTests().check(
        json ? start.stdout : start.stderr,
        "task-blocked" + (json ? ".json" : ".txt"))
      let second = try run(["task", "block", "AC-2", "--on", "ext:acme", "-m", "Acme answer"])
      #expect(second.termination == .exit(0))
      #expect(!(second.stdout + second.stderr).contains("new_party"))
      let failed = try run(["task", "unblock", "AC-1", "AC-404"])
      #expect(failed.termination == .exit(2))
      #expect((failed.stdout + failed.stderr).contains("AC-404"))
      let unblocked = try run([
        "task", "unblock", "AC-1", "task:AC-1", "AC-2", "-m", "Acme answered",
      ])
      #expect(unblocked.termination == .exit(0))
      Golden.forTests().check(unblocked.stdout, "task-unblock" + (json ? ".json" : ".txt"))
      try store.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM task ORDER BY seq")
        #expect(rows.map { $0["status"] as String } == ["todo", "todo"])
        #expect(rows.allSatisfy { ($0["claimed_by"] as String?) == nil })
        #expect(rows.allSatisfy { ($0["follow_up_at"] as String?) == nil })
        let links = try Int.fetchOne(db, sql: "SELECT count(*) FROM link WHERE rel='blocked_by'")
        let events = try Int.fetchOne(db, sql: "SELECT count(*) FROM task_event WHERE kind='block'")
        #expect(links == 0 && events == 2)
      }
    }
  }
}

@Suite(.timeLimit(.minutes(1)))
struct TaskBlockPrivacyCommandTests {
  @Test func explicitWorkspaceFileInputAndSafeOutput() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix)
            VALUES('acme-beta','beta','Beta','BE')
            """)
      }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          ["--ws", "acme"] + args + ["--deterministic", "--json"],
          in: scratch, environment: TaskBlockCommandTests.environment)
      }
      #expect(try run(["task", "add", "Acme", "--start"]).termination == .exit(0))
      #expect(try SiltaBinary.run(["ws", "use", "beta"], in: scratch).termination == .exit(0))
      let secret = "Pwd=" + "acme-secret"
      let file = scratch.appending(path: "answer.md")
      try Data(secret.utf8).write(to: file)
      let block = try run([
        "task", "block", "AC-1", "--on", "url:https://example.com/?" + secret,
        "-F", file.path, "--allow-secret", "--approved", "Keep this Acme answer",
      ])
      #expect(block.termination == .exit(0))
      #expect(!block.stdout.contains("acme-secret") && block.stdout.contains("REDACTED"))
      let show = try run(["task", "show", "AC-1", "--timeline"])
      #expect(show.termination == .exit(0) && !show.stdout.contains("acme-secret"))
      let blocked = try run(["task", "start", "AC-1"])
      #expect(blocked.termination == .exit(6) && !blocked.stdout.contains("acme-secret"))
      #expect(blocked.stdout.contains("--ws 'acme' task ls --status todo"))
      let unblock = try run(["task", "unblock", "AC-1", "-F", file.path])
      #expect(unblock.termination == .exit(0) && unblock.stdout.contains("secret_redacted"))
      #expect(try run(["task", "show", "AC-1"]).stdout.contains("\"status\":\"todo\""))
      let logs = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      #expect(!logs.contains("acme-secret"))
      try store.read { db in
        let commands = try String.fetchAll(db, sql: "SELECT command FROM approval")
        #expect(commands.count == 1 && !commands[0].contains("acme-secret"))
        let body = try #require(
          try String.fetchOne(db, sql: "SELECT body FROM task_event WHERE kind='block'"))
        #expect(body.contains("acme-secret"))
      }
    }
  }
}
