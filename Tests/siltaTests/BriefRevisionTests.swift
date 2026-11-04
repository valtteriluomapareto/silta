import Darwin
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension BriefCommandTests {
  @Test func claimPriorityUsesDistinctTimesBeforeSequenceAndBranchUpdates() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      let store = store(scratch)
      try seedTasks(store)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET claimed_at='2023-11-14T22:00:00.000Z',
              updated_at='2023-11-01T00:00:00.000Z' WHERE seq=2;
            UPDATE task SET claimed_at='2023-11-10T00:00:00.000Z',
              updated_at='2023-11-14T23:00:00.000Z' WHERE seq=3;
            UPDATE task SET updated_at='2023-11-14T23:30:00.000Z' WHERE seq=1;
            """)
      }
      #expect(try fixture.data(run(["--json"], repo, scratch))["current_task"] as? String == "AC-2")
    }
  }

  @Test func completedPlanStepsCollapseAndTailHasRecovery() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      let plan = (1...60).map {
        "- [\($0 <= 7 ? "x" : " ")] Acme step \($0) "
          + String(repeating: "context ", count: 5)
      }.joined(separator: "\n")
      try seedTasks(store(scratch))
      try store(scratch).write {
        try $0.database.execute(sql: "UPDATE task SET plan_md=? WHERE seq=1", arguments: [plan])
      }
      let result = try run(["--task", "AC-1", "--hook"], repo, scratch)
      withKnownIssue("#16: collapse completed work and report plan trimming") {
        #expect(result.stdout.contains("1–7 done"))
        #expect(!result.stdout.contains("1. [x]"))
        #expect(result.stdout.contains("8. [ ] Acme step 8"))
        #expect(result.stdout.contains("(plan trimmed:"))
        #expect(result.stdout.contains("/60; silta --ws 'acme' task show AC-1)"))
      }
    }
  }

  @Test func blockedBranchTaskGuidesWhereAndBriefIdentically() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-qb", "feature/acme", "portal"], repo, scratch)
      try seedTasks(store(scratch))
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            UPDATE task SET claimed_by=NULL,branch=NULL;
            UPDATE task SET branch='feature/acme' WHERE seq=1;
            """)
      }
      let blocked = try SiltaBinary.run(
        ["--ws", "acme", "task", "block", "AC-1", "-m", "Acme waits"], in: scratch,
        cwd: repo, environment: TaskBlockCommandTests.environment)
      try #require(blocked.termination == .exit(0), "\(blocked.stderr)")
      let location = try fixture.data(fixture.run([], repo, scratch))
      let brief = try fixture.data(run(["--json"], repo, scratch))
      withKnownIssue("#16: where and brief must share ranked blocked-task selection") {
        #expect(location["app"] as? String == "api")
        #expect((brief["location"] as? [String: Any])?["app"] as? String == "api")
      }
      #expect(brief["current_task"] as? String == "AC-1")
    }
  }

  @Test func invalidSettingsKeepTaskAndValidPolicies() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.setup(scratch)
      try seedTasks(store(scratch))
      for json in [
        "{\"review_gate\":\"team\",\"proposals\":\"ask\",\"archive_after_days\":null}",
        "{\"future_policy\":{\"password\":\"acme-secret\"},\"proposals\":\"ask\"}",
        "broken-json",
      ] {
        try settings(json, scratch)
        let result = try run(["--task", "AC-4", "--json"], repo, scratch)
        let envelope = try #require(
          try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        withKnownIssue("#16: unsupported settings degrade per key without suppressing context") {
          #expect(envelope["ok"] as? Bool == true)
          #expect((envelope["data"] as? [String: Any])?["current_task"] as? String == "AC-4")
          #expect(!result.stdout.contains("acme-secret"))
          #expect((envelope["warnings"] as? [[String: Any]])?.isEmpty == false)
        }
      }
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
      withKnownIssue("#16: watchdog timeout must leave a command trace") { #expect(bytes != nil) }
      if let bytes {
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 1)
        let entry = try #require(
          try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(entry["command"] as? String == "silta brief")
        #expect(entry["actor"] as? String == "agent:codex:acme")
        #expect(entry["exit_code"] as? Int == 0)
        #expect((entry["warnings"] as? [String])?.contains("hook_timeout") == true)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(repo.path))
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
}
