import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskCommandTests {
  static func setup(_ scratch: URL) throws -> DatabaseStore {
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    try store.write {
      try $0.database.execute(sql: """
        INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC');
        INSERT INTO meta(key,value) VALUES('current_workspace','acme');
        """)
    }
    return store
  }

  static let actor = ["SILTA_ACTOR": "agent:codex:acme"]

  @Test func nonCodeLifecycleAndSessionRefusal() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let added = try SiltaBinary.run(
        ["task", "add", "Acme release", "--start", "--json"],
        in: scratch, environment: Self.actor)
      #expect(added.termination == .exit(0))
      Golden.forTests().check(added.stdout, "task-add.json")
      let rival = try SiltaBinary.run(
        ["task", "start", "AC-1", "--json"], in: scratch,
        environment: ["SILTA_ACTOR": "agent:codex:other"])
      #expect(rival.termination == .exit(6))
      #expect(rival.stdout.contains("\"code\":\"claimed\""))
      let submitted = try SiltaBinary.run(
        ["task", "submit", "AC-1", "--json"], in: scratch, environment: Self.actor)
      #expect(submitted.termination == .exit(0))
      Golden.forTests().check(submitted.stdout, "task-submit.json")
      let done = try SiltaBinary.run(
        ["task", "done", "task:AC-1", "-m", "Released Acme.", "--json"],
        in: scratch, environment: Self.actor)
      #expect(done.termination == .exit(0))
      Golden.forTests().check(done.stdout, "task-done.json")
      try store.read { db in
        let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM task"))
        #expect(row["result_md"] as String == "Released Acme.")
        for column in ["branch", "worktree", "done_sha", "done_branch", "claimed_by"] {
          #expect(row[column] as String? == nil)
        }
      }
    }
  }

  @Test func proposalsAndRequiredResultsAreRecoverable() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let proposed = try SiltaBinary.run(
        ["task", "add", "Acme idea", "--json"], in: scratch, environment: Self.actor)
      #expect(proposed.termination == .exit(0))
      Golden.forTests().check(proposed.stdout, "task-add-proposed.json")
      let refused = try SiltaBinary.run(
        ["task", "start", "AC-1", "--json"], in: scratch, environment: Self.actor)
      #expect(refused.termination == .exit(6))
      Golden.forTests().check(refused.stdout, "task-proposal-refused.json")
      let empty = try SiltaBinary.run(
        ["task", "drop", "AC-1", "--json"], in: scratch, environment: Self.actor)
      #expect(empty.termination == .exit(1))
      #expect(empty.stdout.contains("result"))
      let dropped = try SiltaBinary.run(
        ["task", "drop", "AC-1", "-m", "Not needed.", "--json"],
        in: scratch, environment: Self.actor)
      #expect(dropped.termination == .exit(0))
      Golden.forTests().check(dropped.stdout, "task-drop.json")
    }
  }

  @Test func agentsCannotStealOrAllowSecrets() throws {
    try withScratchDirectory { scratch in
      for args in [
        ["task", "start", "AC-1", "--steal"],
        ["task", "add", "Acme", "--allow-secret"],
        ["task", "done", "AC-1", "--force"],
      ] {
        let result = try SiltaBinary.run(args + ["--json"], in: scratch, environment: Self.actor)
        #expect(result.termination == .exit(3))
        #expect(result.stdout.contains("human_only"))
      }
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path))
    }
  }
}
