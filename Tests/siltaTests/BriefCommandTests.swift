import Darwin
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct BriefCommandTests {
  let fixture = WhereCommandTests()

  @Test func fixtureGoldensAndSettingsFloor() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      for suffix in ["txt", "json"] {
        let flags = suffix == "json" ? ["--json"] : []
        let first = try run(flags, repo, scratch)
        #expect(first.termination == .exit(0), "\(first.stderr)")
        Golden.forTests().check(first.stdout, "brief.\(suffix)")
        #expect(try first == run(flags, repo, scratch))
      }
      try settings(
        "{\"proposals\":\"triage\",\"review_gate\":\"none\","
          + "\"archive_after_days\":14,\"stale_days\":90}",
        scratch)
      Golden.forTests().check(try run([], repo, scratch).stdout, "brief.txt")
      try settings("{\"proposals\":\"ask\"}", scratch)
      for mode in [[], ["--short"], ["--hook"]] {
        let result = try run(mode + ["--budget", "1"], repo, scratch)
        Golden.forTests().check(result.stdout, "brief-settings-minimum.txt")
        let json = try fixture.data(run(mode + ["--budget", "1", "--json"], repo, scratch))
        #expect((json["settings"] as? [String: String]) == ["proposals": "ask"])
      }
    }
  }

  @Test func taskPrecedenceAndPlanProjection() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      let store = store(scratch)
      try seedTasks(store)
      func chosen(_ flags: [String] = []) throws -> String? {
        try fixture.data(run(flags + ["--json"], repo, scratch))["current_task"] as? String
      }
      #expect(try chosen() == "AC-3")
      #expect(try chosen(["--task", "AC-1"]) == "AC-1")
      #expect(try chosen(["--app", "portal"]) == "AC-2")
      let text = try run(["--task", "AC-2", "--app", "api"], repo, scratch).stdout
      Golden.forTests().check(text, "brief-task.txt")
      #expect(text.contains("app: portal"))
      #expect(text.contains("1. [x] Acme ready\n2. [ ] Acme next"))
      let whereData = try fixture.data(fixture.run([], repo, scratch))
      let brief = try fixture.data(run(["--json"], repo, scratch))
      #expect(
        (brief["location"] as? [String: Any])?["app"] as? String == whereData["app"] as? String)
      try store.write { try $0.database.execute(sql: "UPDATE task SET claimed_by=NULL") }
      #expect(try chosen() == "AC-1")
      for (status, external, archive) in [
        ("proposed", "", ""), ("doing", "ado:42", ""), ("doing", "", "archived"),
      ] {
        try store.write {
          try $0.database.execute(
            sql: """
              UPDATE task SET status=?,external_ref=NULLIF(?,''),archive_override=NULLIF(?,''),
                claimed_by='agent:codex:acme' WHERE seq=4
              """, arguments: [status, external, archive])
        }
        #expect(try chosen() == "AC-1")
      }
      try fixture.git(["checkout", "-q", "--detach"], repo, scratch)
      #expect(try chosen() == nil)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET app_id=NULL,external_ref=NULL,archive_override=NULL,
              worktree='/acme/other-repository' WHERE seq=4
            """)
      }
      #expect(try chosen() == nil)
      try store.write { try $0.database.execute(sql: "UPDATE task SET worktree=NULL WHERE seq=4") }
      #expect(try chosen() == "AC-4")
      #expect(try run(["--task", "AC-99"], repo, scratch).termination == .exit(2))
    }
  }

  @Test func hookErrorsAreSilentAndDoNotInitialize() throws {
    try withScratchDirectory { scratch in
      for env in [[:], ["SILTA_ACTOR": "bad"], ["SILTA_NOW": "bad"]] {
        let result = try SiltaBinary.run(
          ["brief", "--hook", "--json", "--verbose"], in: scratch, environment: env)
        #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      }
      #expect(!FileManager.default.fileExists(atPath: store(scratch).path))
      let repo = try fixture.setup(scratch)
      let outside = scratch.appending(path: "fixtures/acme-detached")
      #expect(try run(["--hook"], outside, scratch).stdout.isEmpty)
      try settings("{\"proposals\":null}", scratch)
      #expect(try run([], repo, scratch).termination == .exit(1))
      #expect(
        try run(["--hook", "--json", "--verbose"], repo, scratch)
          == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
    }
  }

  @Test func budgetsTrimPlanAndExplicitBudgetOverridesShortDefault() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,plan_md,
              created_by,created_at,updated_at)
            VALUES('acme-long',1,1,'Acme long','todo',?,'human:acme','','')
            """, arguments: [String(repeating: "- [ ] Acme 👩🏽‍💻é context\n", count: 300)])
      }
      let regular = try run(["--task", "AC-1"], repo, scratch)
      let short = try run(["--task", "AC-1", "--short"], repo, scratch)
      #expect(short.stdout.count <= 3200)
      #expect(short.stdout.count < regular.stdout.count)
      #expect(try run(["--task", "AC-1", "--short", "--budget", "2500"], repo, scratch) == regular)
      #expect(try run(["--task", "AC-1", "--hook", "--budget", "2500"], repo, scratch) == regular)
      let value = try fixture.data(run(["--task", "AC-1", "--short", "--json"], repo, scratch))
      #expect(value["truncated"] as? Bool == true)
      let sections = try #require(value["sections"] as? [[String: String]])
      #expect(sections.compactMap { $0["text"] }.joined().count < 3200)
    }
  }

  @Test func hookDoesNotWaitForDatabaseLock() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      var config = Configuration()
      config.allowsUnsafeTransactions = true
      let queue = try DatabaseQueue(path: store(scratch).path, configuration: config)
      try queue.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE")
        defer { try? db.execute(sql: "ROLLBACK") }  // best-effort release after assertion
        let result = try SiltaBinary.run(
          ["brief", "--hook", "--json", "--verbose"],
          in: scratch, cwd: repo,
          environment: [
            "SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z",
          ], timeout: 2)
        #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      }
    }
  }

  @Test(arguments: ["git", "database"])
  func hookBoundsBlockedIO(kind: String) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let fifo = scratch.appending(path: "blocked")
      try #require(mkfifo(fifo.path, 0o600) == 0)
      if kind == "git" {
        let config = repo.appending(path: ".git/config")
        var text = try String(contentsOf: config, encoding: .utf8)
        text += "\n[include]\npath = \(fifo.path)\n"
        try Data(text.utf8).write(to: config)
      } else {
        let path = store(scratch).path
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: fifo.path, toPath: path)
      }
      let clock = ContinuousClock()
      let started = clock.now
      let result = try SiltaBinary.run(
        ["brief", "--hook", "--json", "--verbose"], in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex"], timeout: 2.5)
      #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      #expect(started.duration(to: clock.now) < .seconds(2))
      if kind == "git" {
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
        let failure = errno
        if descriptor >= 0 { close(descriptor) }
        withKnownIssue("#16: hook must reap blocked Git before exiting") {
          #expect(descriptor == -1 && failure == ENXIO, "Git reader survived hook exit")
        }
      }
    }
  }

  @Test func blockersMatchStartRecoveryAndSecretsStayMasked() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      for title in ["Acme work", "Acme prerequisite"] {
        let added = try SiltaBinary.run(
          ["--ws", "acme", "task", "add", title, "--app", "api", "--start"],
          in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
        try #require(added.termination == .exit(0), "\(added.stderr)")
      }
      let blocked = try SiltaBinary.run(
        ["--ws", "acme", "task", "block", "AC-1", "--on", "task:AC-2", "-m", "Acme waits"],
        in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      try #require(blocked.termination == .exit(0), "\(blocked.stderr)")
      for status in ["doing", "done", "dropped"] {
        try store(scratch).write {
          try $0.database.execute(sql: "UPDATE task SET status=? WHERE seq=2", arguments: [status])
        }
        let refusal = try SiltaBinary.run(
          ["--ws", "acme", "task", "start", "AC-1", "--json"],
          in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
        let envelope = try #require(
          try JSONSerialization.jsonObject(with: Data(refusal.stdout.utf8)) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        let text = try run(["--task", "AC-1"], repo, scratch).stdout
        for next in try #require(error["next"] as? [String]) {
          #expect(text.contains("next: " + next + "\n"))
        }
        #expect(text.contains("for 0 d."))
      }
      try store(scratch).write {
        try $0.database.execute(
          sql: "UPDATE task SET title='Pwd=acme-secret',plan_md='- [ ] Pwd=acme-secret' WHERE seq=1"
        )
      }
      for flags in [[], ["--json"], ["--hook", "--json"]] {
        let result = try run(["--task", "AC-1"] + flags, repo, scratch)
        #expect(!result.stdout.contains("acme-secret"))
        #expect(result.stdout.contains("REDACTED"))
      }
    }
  }

  func seedTasks(_ store: DatabaseStore) throws {
    try store.write { tx in
      for (seq, app, actor, branch, status) in [
        (1, "api", "agent:codex:other", "api", "doing"),
        (2, "portal", "agent:codex:acme", "elsewhere", "doing"),
        (3, "api", "agent:codex:acme", "elsewhere", "doing"),
        (4, "api", "agent:codex:acme", "api", "done"),
      ] {
        try tx.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,claimed_at,
              branch,created_by,created_at,updated_at,plan_md)
            SELECT ?,workspace_id,?,'Acme task',?,id,?,'2023-11-14T22:13:20.000Z',?,
              'human:acme','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z',
              '- [x] Acme ready
            - [ ] Acme next'
            FROM app WHERE slug=?
            """, arguments: ["acme-\(seq)", seq, status, actor, branch, app])
      }
    }
  }

  func run(_ flags: [String], _ repo: URL, _ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["brief", "--ws", "acme"] + flags, in: scratch, cwd: repo,
      environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
  }

  func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  func settings(_ json: String, _ scratch: URL) throws {
    try store(scratch).write {
      try $0.database.execute(sql: "UPDATE workspace SET settings=?", arguments: [json])
    }
  }
}
