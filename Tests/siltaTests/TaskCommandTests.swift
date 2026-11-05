import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
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

  /// The agent at a fixed instant, for goldens that carry timestamps.
  static let fixed = actor.merging(["SILTA_NOW": "2023-11-14T22:13:20.000Z"]) { $1 }

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
        ["task", "add", "Acme idea", "--json"], in: scratch, environment: Self.fixed)
      #expect(proposed.termination == .exit(0))
      Golden.forTests().check(proposed.stdout, "task-add-proposed.json")
      for command in ["ls", "show"] {
        for json in [false, true] {
          let args =
            ["task", command] + (command == "show" ? ["AC-1"] : [])
            + (json ? ["--json"] : [])
          let read = try SiltaBinary.run(args, in: scratch, environment: Self.fixed)
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

  @Test func agentsCannotAllowSecretsBeforeStorageOpens() throws {
    try withScratchDirectory { scratch in
      for args in [
        ["task", "add", "Acme", "--allow-secret"],
        ["task", "done", "AC-1", "--allow-secret"],
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
      let made = try AcmeFixtures.make(at: fixtures, in: scratch)
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
  /// The merger finishes a submitted task from the main checkout after the author's
  /// worktree is gone (D41).
  @Test func mergerFinishesWithShaAfterTheWorktreeIsRemoved() throws {
    try withScratchDirectory { scratch in
      let fixtures = scratch.appending(path: "acme")
      let git = URL(filePath: "/usr/bin/git")
      #expect(
        try AcmeFixtures.make(at: fixtures, in: scratch).termination == .exit(0))
      #expect(
        try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch).termination == .exit(0))
      #expect(try SiltaBinary.run(["ws", "use", "acme"], in: scratch).termination == .exit(0))
      let repo = fixtures.appending(path: "acme-platform", directoryHint: .isDirectory)
      let tree = scratch.appending(path: "acme-feature", directoryHint: .isDirectory)
      #expect(
        try SiltaBinary.runProcess(
          git, ["-C", repo.path, "worktree", "add", "-q", "-b", "acme-feature", tree.path],
          in: scratch
        ).termination == .exit(0))
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme app", "--app", "acme-platform-api", "--start"],
          in: scratch, cwd: tree, environment: Self.actor
        ).termination == .exit(0))
      #expect(
        try SiltaBinary.run(["task", "submit", "AC-1"], in: scratch, environment: Self.actor)
          .termination == .exit(0))
      #expect(
        try SiltaBinary.runProcess(
          git, ["-C", repo.path, "worktree", "remove", "--force", tree.path], in: scratch
        ).termination == .exit(0))
      let head = try SiltaBinary.runProcess(
        git, ["-C", repo.path, "rev-parse", "HEAD"], in: scratch)
      let sha = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let done = try SiltaBinary.run(
        ["task", "done", "AC-1", "--sha", sha, "-m", "Merged."], in: scratch, cwd: repo,
        environment: ["SILTA_ACTOR": "agent:claude:merger"])
      #expect(done.termination == .exit(0))
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1", "--json"], in: scratch, environment: Self.actor)
      #expect(shown.stdout.contains(#""done_sha":"\#(sha)""#))
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
      #expect(invalid.termination == .exit(1))
      let missing = try SiltaBinary.run(
        ["task", "add", "Acme", "-F", file.path + "-absent", "--json"], in: scratch,
        environment: Self.actor)
      #expect(missing.termination == .exit(1))
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 1)
    }
  }
}

extension TaskCommandTests {
  @Test func humanOnlyRecoveryRetainsTaskAndFileInput() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      for actor in ["agent:codex:other", "agent:codex:acme"] {
        let added = try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch, environment: ["SILTA_ACTOR": actor])
        #expect(added.termination == .exit(0))
      }
      try store.write {
        try $0.database.execute(sql: #"UPDATE workspace SET settings='{"review_gate":"human"}'"#)
      }
      for (args, expected) in [
        (["task", "start", "AC-1", "--steal"], "silta task start 'AC-1' --steal"),
        (
          ["task", "done", "AC-2", "--force", "-m", "Acme done"],
          "silta task done 'AC-2' --force -F <file>"
        ),
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
        #expect(error["next"] as? [String] == [expected + " --approved \"<the human's words>\""])
      }
    }
  }
}

extension TaskCommandTests {
  /// An initialized Acme workspace from the scenario fixtures, with its platform repo.
  private static func appWorkspace(_ scratch: URL) throws -> URL {
    let fixtures = scratch.appending(path: "acme")
    #expect(
      try AcmeFixtures.make(at: fixtures, in: scratch).termination == .exit(0))
    #expect(
      try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch).termination
        == .exit(0))
    #expect(try SiltaBinary.run(["ws", "use", "acme"], in: scratch).termination == .exit(0))
    return fixtures.appending(path: "acme-platform", directoryHint: .isDirectory)
  }

  /// A subtask's inherited app is visible where it matters, `--app none` opts out, and
  /// a wrong working directory is the agent's mistake to fix.
  @Test func inheritedAppsAreVisibleAndCanBeOptedOut() throws {
    try withScratchDirectory { scratch in
      let repo = try Self.appWorkspace(scratch)
      let app = "acme-platform-api"
      let root = try SiltaBinary.run(
        ["task", "add", "Acme app work", "--app", app, "--start"], in: scratch, cwd: repo,
        environment: Self.actor)
      #expect(root.termination == .exit(0))
      let inherited = try SiltaBinary.run(
        ["task", "add", "Acme child", "--parent", "AC-1"], in: scratch, environment: Self.actor)
      #expect(inherited.termination == .exit(0))
      Golden.forTests().check(inherited.stdout, "task-add-inherited-app.txt")
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-2"], in: scratch, environment: Self.actor)
      #expect(shown.termination == .exit(0))
      Golden.forTests().check(shown.stdout, "task-show-inherited-app.txt")
      let plan = scratch.appending(path: "plan.md")
      try "# Acme release\n\nContext\n\n- First\n- Second\n".write(
        to: plan, atomically: true, encoding: .utf8)
      let preview = try SiltaBinary.run(
        ["task", "from-plan", plan.path, "--parent", "AC-1", "--split", "--dry-run"],
        in: scratch, environment: Self.actor)
      #expect(preview.termination == .exit(0))
      Golden.forTests().check(preview.stdout, "task-from-plan-inherited-app-preview.txt")
      let json = try SiltaBinary.run(
        ["task", "from-plan", plan.path, "--parent", "AC-1", "--split", "--dry-run", "--json"],
        in: scratch, environment: Self.actor)
      #expect(json.termination == .exit(0))
      Golden.forTests().check(json.stdout, "task-from-plan-inherited-app-preview.json")
      let none = try SiltaBinary.run(
        ["task", "add", "Acme release", "--parent", "AC-1", "--app", "none"],
        in: scratch, environment: Self.actor)
      #expect(none.termination == .exit(0))
      #expect(none.stdout == "AC-3 todo\n")
      let nonCode = try SiltaBinary.run(
        ["task", "show", "AC-3"], in: scratch, environment: Self.actor)
      #expect(nonCode.termination == .exit(0) && !nonCode.stdout.contains("App:"))
      let notes = scratch.appending(path: "notes", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
      let refused = try SiltaBinary.run(
        ["task", "add", "Acme child", "--parent", "AC-1", "--start"], in: scratch, cwd: notes,
        environment: Self.actor)
      #expect(refused.termination == .exit(1))
      #expect(refused.stderr.contains("inherited from AC-1"))
      #expect(refused.stderr.contains("--app none"))
      let real = try SiltaBinary.run(
        ["task", "from-plan", plan.path, "--parent", "AC-1", "--split"],
        in: scratch, environment: Self.actor)
      #expect(real.termination == .exit(0))
      Golden.forTests().check(real.stdout, "task-from-plan-inherited-app.txt")
    }
  }
}
