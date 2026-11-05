import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

struct SessionCheckTests {
  static let environment = [
    "CLAUDECODE": "1", "SILTA_SESSION": "acme-session",
    "SILTA_NOW": "2023-11-14T22:13:20.000Z",
  ]

  static func run(
    _ args: [String], in scratch: URL, environment: [String: String] = SessionCheckTests.environment
  ) throws -> CLIResult {
    try SiltaBinary.run(args, in: scratch, environment: environment)
  }

  static func tasks(in scratch: URL, environment: [String: String] = SessionCheckTests.environment)
    throws -> [[String: String]]
  {
    try #require(
      try AgentsInstallTests.data(
        run(["session", "check", "--json"], in: scratch, environment: environment))["tasks"]
        as? [[String: String]])
  }

  @Test func stopHookChecksOwnWritesAndHandoffAcrossProcesses() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--stop-hook"], in: scratch)
          .termination == .exit(0))
      let command = try AgentsHookTests.command("Stop", in: scratch)
      #expect(try AgentsHookTests.command("SessionStart", in: scratch).contains("session-start"))
      #expect(
        try Self.run(["task", "add", "Acme work", "--start"], in: scratch).termination == .exit(0))
      #expect(try Self.tasks(in: scratch).isEmpty)
      #expect(
        try Self.run(["task", "plan", "AC-1", "-m", "- [ ] Acme next"], in: scratch).termination
          == .exit(0))
      #expect(try Self.tasks(in: scratch) == [["workspace": "acme", "ref": "AC-1"]])
      #expect(try Self.run(["task", "start", "AC-1"], in: scratch).termination == .exit(0))
      #expect(try Self.tasks(in: scratch).count == 1)
      let payload = #"{"session_id":"acme-session","stop_hook_active":false}"#
      let blocked = try AgentsHookTests.hook(
        command, payload: payload, in: scratch, environment: Self.environment)
      #expect(blocked.termination == .exit(0))
      let result = try GuideContractTests.object(blocked.stdout)
      #expect(result["decision"] as? String == "block")
      #expect((result["reason"] as? String)?.contains("AC-1") == true)
      let active = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme-session","stop_hook_active":true}"#, in: scratch,
        environment: Self.environment)
      #expect(active.termination == .exit(0) && active.stdout.isEmpty && active.stderr.isEmpty)
      let other = Self.environment.merging(["SILTA_SESSION": "other"]) { _, new in new }
      #expect(try Self.tasks(in: scratch, environment: other).isEmpty)
      let expired = Self.environment.merging(["SILTA_NOW": "2023-11-15T00:13:20.000Z"]) { _, new in
        new
      }
      #expect(try Self.tasks(in: scratch, environment: expired).isEmpty)
      #expect(
        try Self.run(
          [
            "comment", "AC-1", "--kind", "handoff", "-m",
            "State: Acme saved. Next: review. Open questions: none.",
          ], in: scratch
        ).termination == .exit(0))
      #expect(try Self.tasks(in: scratch).isEmpty)
      #expect(
        try AgentsHookTests.hook(
          command, payload: payload, in: scratch, environment: Self.environment
        ).stdout.isEmpty)
      #expect(try Self.run(["task", "start", "AC-1"], in: scratch).termination == .exit(0))
      #expect(try Self.tasks(in: scratch).isEmpty)
      #expect(
        try Self.run(["comment", "AC-1", "-m", "Acme context"], in: scratch).termination == .exit(0)
      )
      #expect(try Self.tasks(in: scratch).count == 1)
      #expect(
        try AgentsInstallTests.apply(["uninstall", "--claude"], in: scratch).termination == .exit(0)
      )
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "home/.claude/settings.json").path))
    }
  }

  @Test func deletingOldContextIsStillAWriteAfterHandoff() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      for args in [
        ["task", "add", "Acme work", "--start"], ["comment", "AC-1", "-m", "Acme context"],
        ["comment", "AC-1", "--kind", "handoff", "-m", "State: Acme saved. Next: review."],
        ["task", "start", "AC-1"], ["comment", "delete", "AC-1/1"],
      ] {
        #expect(try Self.run(args, in: scratch).termination == .exit(0))
      }
      #expect(try Self.tasks(in: scratch).count == 1)
      let audit = try store.read {
        try Int.fetchOne(
          $0, sql: "SELECT count(*) FROM task_event WHERE kind='discussion' AND body LIKE '%AC-1/1'"
        )
      }
      #expect(audit == 1)
    }
  }
}

extension SessionCheckTests {
  @Test func checksAreReadOnlyAndDoNotInitializeOrMigrate() throws {
    try withScratchDirectory { scratch in
      let missing = try Self.run(["session", "check", "--json"], in: scratch)
      #expect(missing.termination == .exit(9))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql:
            "DELETE FROM grdb_migrations WHERE identifier='v4'; UPDATE meta SET value='3' WHERE key='min_writer_version'"
        )
      }
      let before = try store.read { try Int.fetchOne($0, sql: "SELECT max(seq) FROM change_log") }
      let result = try Self.run(["session", "check", "--json"], in: scratch)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "session-check.json")
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT max(seq) FROM change_log") } == before)
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
        } == "3")
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier='v4'")
        } == 0)
      try store.write { try $0.database.execute(sql: "DROP TABLE comment") }
      #expect(try Self.run(["session", "check", "--json"], in: scratch).termination == .exit(9))
      #expect(try store.read { try $0.tableExists("comment") } == false)
    }
  }

  @Test func stopRecoveryCommandsAddressEveryWorkspace() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      try store.write {
        try $0.database.execute(
          sql:
            "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Acme Beta','BE')"
        )
      }
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--stop-hook"], in: scratch)
          .termination == .exit(0))
      for (workspace, ref) in [("acme", "AC-1"), ("beta", "BE-1")] {
        #expect(
          try Self.run(["--ws", workspace, "task", "add", "Acme work", "--start"], in: scratch)
            .termination == .exit(0))
        #expect(
          try Self.run(
            ["--ws", workspace, "task", "plan", ref, "-m", "- [ ] Acme next"], in: scratch
          ).termination == .exit(0))
      }
      #expect(try Self.tasks(in: scratch).map { $0["workspace"] } == ["acme", "beta"])
      let command = try AgentsHookTests.command("Stop", in: scratch)
      let blocked = try AgentsHookTests.hook(
        command, payload: #"{"session_id":"acme-session"}"#, in: scratch,
        environment: Self.environment)
      let reason = try #require(try GuideContractTests.object(blocked.stdout)["reason"] as? String)
      let commands = reason.split(separator: "\n").map(String.init).filter {
        $0.hasPrefix("silta ")
      }
      #expect(commands.count == 2)
      let path = try SiltaBinary.url().deletingLastPathComponent().path + ":/usr/bin:/bin"
      for command in commands {
        let script =
          command
          + " <<'HANDOFF'\nState: Acme saved. Next step: review. Open questions: none.\nHANDOFF\n"
        let result = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", script], in: scratch,
          environment: Self.environment.merging(["PATH": path]) { _, new in new })
        #expect(result.termination == .exit(0))
      }
      #expect(try Self.tasks(in: scratch).isEmpty)
      #expect(
        try AgentsHookTests.hook(
          command, payload: #"{"session_id":"acme-session","stop_hook_active":"bad"}"#, in: scratch,
          environment: Self.environment
        ).stdout.isEmpty)
      #expect(
        try AgentsInstallTests.apply(["install", "--claude", "--hook"], in: scratch).termination
          == .exit(0))
      #expect(try AgentsHookTests.command("Stop", in: scratch) == command)
      let invalid = try AgentsInstallTests.run(
        ["install", "--codex", "--stop-hook", "--json"], in: scratch)
      #expect(invalid.termination == .exit(1))
    }
  }
}
