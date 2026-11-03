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
      try $0.database.execute(
        sql: """
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
      let started = try SiltaBinary.run(
        ["task", "start", "AC-1", "--json"], in: scratch, environment: Self.actor)
      #expect(started.termination == .exit(0))
      Golden.forTests().check(started.stdout, "task-start.json")
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
      for command in ["ls", "show"] {
        for json in [false, true] {
          let args =
            ["task", command] + (command == "show" ? ["AC-1"] : [])
            + (json ? ["--json"] : [])
          let read = try SiltaBinary.run(args, in: scratch, environment: Self.actor)
          #expect(read.termination == .exit(0))
          Golden.forTests().check(read.stdout, "task-" + command + (json ? ".json" : ".txt"))
        }
      }
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
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }
}

extension TaskCommandTests {
  @Test func realAppCompletionUsesStoredWorktreeAndWarnsOnDirtyChanges() throws {
    try withScratchDirectory { scratch in
      let fixtures = scratch.appending(path: "acme")
      let made = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        [
          ScenarioRunner.repository.appending(path: "scripts/make-fixtures.sh").path, fixtures.path,
        ], in: scratch)
      #expect(made.termination == .exit(0))
      #expect(
        try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch).termination == .exit(0))
      #expect(try SiltaBinary.run(["ws", "use", "acme"], in: scratch).termination == .exit(0))
      let repo = fixtures.appending(path: "acme-platform", directoryHint: .isDirectory)
      let added = try SiltaBinary.run(
        ["task", "add", "Acme app", "--app", "acme-platform-api", "--start", "--json"],
        in: scratch, cwd: repo, environment: Self.actor)
      #expect(added.termination == .exit(0))
      try "Acme dirty change\n".write(
        to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      let done = try SiltaBinary.run(
        ["task", "done", "AC-1", "-m", "Completed app.", "--json"],
        in: scratch, environment: Self.actor)
      #expect(done.termination == .exit(0))
      #expect(done.stdout.contains("dirty_worktree"))
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1", "--json"], in: scratch, environment: Self.actor)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any])
      let data = try #require(object["data"] as? [String: Any])
      #expect((data["done_sha"] as? String)?.count == 40)
      #expect(data["done_branch"] as? String == "api")
      #expect(data["done_dirty"] as? Bool == true)
      #expect(data["worktree"] as? String == repo.path)
    }
  }
}

extension TaskCommandTests {
  @Test func bodyFilesAndConflictingSourcesHaveExplicitFailures() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      let file = scratch.appending(path: "body.md")
      try "Acme description".write(to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        ["task", "add", "Acme body", "-F", file.path, "--json"], in: scratch,
        environment: Self.actor)
      #expect(result.termination == .exit(0))
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT description_md FROM task") }
          == "Acme description")
      let conflict = try SiltaBinary.run(
        ["task", "add", "Acme", "-m", "Body", "-F", file.path, "--json"], in: scratch,
        environment: Self.actor)
      #expect(conflict.termination == .exit(1))
      #expect(conflict.stdout.contains("Use either -m or -F"))
      try Data([255]).write(to: file)
      let invalid = try SiltaBinary.run(
        ["task", "add", "Acme", "-F", file.path, "--json"], in: scratch, environment: Self.actor)
      #expect(invalid.termination == .exit(9))
      let missing = try SiltaBinary.run(
        ["task", "add", "Acme", "-F", file.path + "-absent", "--json"], in: scratch,
        environment: Self.actor)
      #expect(missing.termination == .exit(9))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 1)
    }
  }
}

extension TaskCommandTests {
  @Test func humanOnlyRecoveryRetainsTaskAndFileInput() throws {
    try withScratchDirectory { scratch in
      for (args, expected) in [
        (["task", "start", "AC-7", "--steal"], "silta task start 'AC-7' --steal"),
        (["task", "done", "AC-7", "--force"], "silta task done 'AC-7' --force -F <file>"),
        (
          ["task", "done", "AC-7", "--allow-secret"],
          "silta task done 'AC-7' --allow-secret -F <file>"
        ),
      ] {
        let result = try SiltaBinary.run(args + ["--json"], in: scratch, environment: Self.actor)
        let object = try #require(
          JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(result.termination == .exit(3))
        #expect(error["next"] as? [String] == [expected])
      }
    }
  }
}
