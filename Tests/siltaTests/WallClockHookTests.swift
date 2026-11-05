import Darwin
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// Wall-clock proof of the hook's 1.5 s process deadline (spec §12) through the built
/// binary, and the hook-output checks the parallel suite skips when that deadline trips.
/// A wall-clock assertion can't tell a slow hook from a busy machine, so these run only
/// in the isolated deadline tier (`deadlineTestsEnabled()`), which `scripts/verify.sh
/// full` runs serially after the parallel suite. `BriefHookDeadlineTests` checks the
/// same timing decisions on a fake clock in every run.
@Suite(
  .tags(.deadline), .enabled(if: deadlineTestsEnabled()), .serialized, .blockingTestWork,
  .timeLimit(.minutes(3)))
struct WallClockHookTests {
  let brief = BriefCommandTests()
  var fixture: WhereCommandTests { brief.fixture }

  func run(_ flags: [String], _ repo: URL, _ scratch: URL) throws -> CLIResult {
    try brief.run(flags, repo, scratch)
  }

  func store(_ scratch: URL) -> DatabaseStore { brief.store(scratch) }

  func contextFixture(_ scratch: URL) throws -> URL { try brief.contextFixture(scratch) }

  /// The discussion tests' hook runs skip when the deadline trips; here a hook brief with
  /// a handoff, caller items and an inbox must finish and equal the short brief.
  @Test func hookDiscussionMatchesTheShortBriefWithinTheDeadline() throws {
    try withScratchDirectory { scratch in
      let repo = try brief.discussionFixture(scratch)
      let task = ["--task", "AC-2", "--app", "api"]
      let short = try run(task + ["--short"], repo, scratch)
      #expect(short.stdout.contains("handoff AC-2/1 by agent:codex:old"))
      #expect(short.stdout.contains("inbox: 3 items for agent:codex:acme (1 on this task)\n"))
      let hook = try run(task + ["--hook"], repo, scratch)
      let warnings = try DogfoodLogTests.last(scratch)["warnings"] as? [String] ?? []
      #expect(!warnings.contains("hook_timeout"))
      #expect(hook == short)
    }
  }

  /// The parallel suite skips this comparison when a busy machine trips the deadline;
  /// here the hook must finish in time.
  @Test func hookOutputMatchesTheShortBriefWithinTheDeadline() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,plan_md,
              created_by,created_at,updated_at)
            VALUES('acme-long',1,1,'Acme long','todo',?,'human:acme','','')
            """, arguments: [String(repeating: "- [ ] Acme 👩🏽‍💻é context\n", count: 300)])
      }
      let regular = try run(["--task", "AC-1"], repo, scratch)
      let short = try run(["--task", "AC-1", "--short"], repo, scratch)
      #expect(try run(["--task", "AC-1", "--hook"], repo, scratch) == short)
      #expect(try run(["--task", "AC-1", "--hook", "--budget", "2500"], repo, scratch) == regular)
      #expect(try brief.hookTimeoutCount(scratch) == 0)
    }
  }

  /// The parallel suite skips these log checks when a busy machine trips the deadline.
  @Test func hookLogKeepsLocationWarningsWithinTheDeadline() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["update-ref", "-d", "refs/remotes/origin/portal"], repo, scratch)
      for flags in [["--hook", "--json", "--verbose"], ["--hook"]] {
        let result = try run(flags, repo, scratch)
        #expect(result.termination == .exit(0) && result.stderr.isEmpty)
        if flags.contains("--json") { #expect(result.stdout.contains("ref_missing")) }
        #expect(try DogfoodLogTests.last(scratch)["warnings"] as? [String] == ["ref_missing"])
      }
      #expect(try brief.hookTimeoutCount(scratch) == 0)
    }
  }

  @Test func hookLogRecordsItsActualExitAndKeepsDiagnosticCode() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let result = try run(["--task", "AC-99", "--hook", "--json", "--verbose"], repo, scratch)
      #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      let entry = try DogfoodLogTests.last(scratch)
      #expect(entry["exit_code"] as? Int == 0)
      #expect(entry["error_code"] as? String == "not_found")
      let log = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"),
        encoding: .utf8)
      #expect(log.split(separator: "\n").count == 1)
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
        let entry = try DogfoodLogTests.last(scratch)
        #expect(entry["error_code"] as? String == "busy")
        #expect(!(entry["warnings"] as? [String] ?? []).contains("hook_timeout"))
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
        environment: ["SILTA_ACTOR": "agent:codex", "SILTA_NOW": "2023-11-14T22:13:20.000Z"],
        timeout: 2.5)
      #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      #expect(started.duration(to: clock.now) < .seconds(2))
      if kind == "git" {
        let warnings = try DogfoodLogTests.last(scratch)["warnings"] as? [String]
        #expect(warnings?.contains("hook_timeout") == true)
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
        let failure = errno
        if descriptor >= 0 { close(descriptor) }
        #expect(descriptor == -1 && failure == ENXIO, "Git reader survived hook exit")
      }
    }
  }

  @Test func successfulHookDoesNotBlockOnLogFIFO() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let directory = scratch.appending(path: "silta-home/log")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try #require(mkfifo(directory.appending(path: "2023-11-14.jsonl").path, 0o600) == 0)
      let result = try SiltaBinary.run(
        ["brief", "--hook"], in: scratch, cwd: repo,
        environment: TaskBlockCommandTests.environment, timeout: 2)
      #expect(result.termination == .exit(0))
      #expect(result.stderr.isEmpty)
      #expect(result.stdout.count <= 3200)
    }
  }

  @Test func watchdogWritesOneBodyFreeTraceAndDoesNotBlockOnLogFIFO() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let path = store(scratch).path
      try FileManager.default.removeItem(atPath: path)
      try #require(mkfifo(path, 0o600) == 0)
      let log = scratch.appending(path: "silta-home/log/2023-11-14.jsonl")
      let result = try run(["--hook"], repo, scratch)
      #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      let bytes = FileManager.default.contents(atPath: log.path)
      #expect(bytes != nil)
      if let bytes {
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let entry = try #require(
          try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(entry["command"] as? String == "silta brief")
        #expect(entry["actor"] as? String == "agent:codex:acme")
        #expect(entry["exit_code"] as? Int == 0)
        #expect((entry["warnings"] as? [String])?.contains("hook_timeout") == true)
        #expect(!text.contains(repo.path))
        try FileManager.default.removeItem(at: log)
      } else {
        try FileManager.default.createDirectory(
          at: log.deletingLastPathComponent(),
          withIntermediateDirectories: true)
      }
      try #require(mkfifo(log.path, 0o600) == 0)
      let clock = ContinuousClock()
      let started = clock.now
      #expect(try run(["--hook"], repo, scratch) == result)
      #expect(started.duration(to: clock.now) < .seconds(2))
    }
  }

  /// Scale under the same deadline: mostly done rows and 5k open answered questions for
  /// another actor. It also needs the slow tier.
  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func hookWithTwentyThousandTasks() throws {
    try withScratchDirectory { scratch in
      let repo = try contextFixture(scratch)
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            WITH RECURSIVE n(x) AS (VALUES(5) UNION ALL SELECT x+1 FROM n WHERE x<20004)
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,description_md,plan_md,
              result_md,closed_at,created_by,created_at,updated_at)
            SELECT 'bulk-'||x,1,x,'Acme backlog',CASE WHEN x%10=0 THEN 'todo' ELSE 'done' END,
              app.id,?,?,?,CASE WHEN x%10=0 THEN NULL ELSE '2023-11-14T20:00:00.000Z' END,
              'human:acme','',''
            FROM n,app WHERE app.slug='api';
            WITH RECURSIVE n(x) AS (VALUES(5) UNION ALL SELECT x+4 FROM n WHERE x<20000)
            INSERT INTO comment(uid,task_id,seq,kind,body_md,mentions,actor,resolved_at,
              resolved_by,created_at)
            SELECT 'bulk-q-'||x,task.id,1,'question',?,'["human:acme"]','agent:codex:other',
              NULL,NULL,'2023-11-14T20:00:00.000Z'
            FROM n JOIN task ON task.seq=n.x;
            INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,mentions,actor,created_at)
            SELECT 'bulk-a-'||task_id,task_id,2,id,'answer',body_md,'[]','human:acme',
              '2023-11-14T20:30:00.000Z'
            FROM comment WHERE uid LIKE 'bulk-q-%';
            """,
          arguments: StatementArguments(
            Array(repeating: String(repeating: "Acme unused ", count: 180), count: 4)))
      }
      let full = try run(["--task", "AC-2", "--app", "api", "--budget", "5000"], repo, scratch)
      #expect(full.stdout.contains("open: AC-1"))
      #expect(full.stdout.contains("done: AC-20004"))
      let clock = ContinuousClock()
      let started = clock.now
      let hook = try run(["--task", "AC-2", "--app", "api", "--hook"], repo, scratch)
      let elapsed = started.duration(to: clock.now)
      let entry = try DogfoodLogTests.last(scratch)
      let warnings = entry["warnings"] as? [String] ?? []
      #expect(hook.stdout.contains("task: AC-2\n"), "empty after \(elapsed): \(entry)")
      #expect(hook.stdout.contains("open: AC-1"))
      #expect(!warnings.contains("hook_timeout"))
    }
  }
}
