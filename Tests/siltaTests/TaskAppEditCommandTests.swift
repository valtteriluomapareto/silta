import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct TaskAppEditCommandTests {
  private static let sourceActor = TaskCommandTests.fixed
  private static let targetActor = sourceActor.merging(["SILTA_ACTOR": "agent:codex:web"]) { $1 }

  @Test func movesBetweenReposAndCompletesFromTheTargetAfterHandoff() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.fixture(scratch)
      try Self.addTasks(fixture, in: scratch)
      let original = try Self.task("AC-1", in: scratch)
      let sameRepo = try Self.run(["task", "edit", "AC-1", "--app", "desk", "--json"], in: scratch)
      try #require(sameRepo.termination == .exit(0), "\(sameRepo.stdout)\(sameRepo.stderr)")
      Golden.forTests().check(sameRepo.stdout, "task-edit-app.json")
      let inDesk = try Self.task("AC-1", in: scratch)
      #expect(inDesk["branch"] as? String == "main")
      #expect(inDesk["worktree"] as? String == original["worktree"] as? String)
      #expect(inDesk["claimed_by"] as? String == original["claimed_by"] as? String)
      #expect(inDesk["description"] as? String == "Preserve Acme evidence.")
      let changedRepo = try Self.run(["task", "edit", "AC-1", "--app", "web"], in: scratch)
      try #require(changedRepo.termination == .exit(0), "\(changedRepo.stderr)")
      #expect(changedRepo.stdout == "AC-1 app:desk -> app:web\n")
      try Self.checkAfterMove(in: scratch)
      try Self.resumeAndFinish(fixture, in: scratch)
    }
  }

  @Test func keepsConsentBoundToTheOriginalWorkspaceAndRollsBackLateFailure() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.fixture(scratch)
      try Self.addTasks(fixture, in: scratch)
      let submitted = try Self.run(["task", "submit", "AC-1"], in: scratch)
      try #require(submitted.termination == .exit(0), "\(submitted.stderr)")
      let denied = try Self.run(
        ["task", "edit", "AC-1", "--app", "web", "--json"], in: scratch, actor: Self.targetActor)
      try #require(denied.termination == .exit(3), "\(denied.stdout)\(denied.stderr)")
      let error = try TaskStateCommandTests.error(denied)
      #expect(error["next_by"] as? String == "human")
      #expect(
        error["next"] as? [String] == [
          #"silta --ws 'acme' task edit 'AC-1' --app 'web' --approved "<the human's words>""#
        ])
      let unknown = try Self.run(
        ["task", "edit", "AC-1", "--app", "absent", "--json"],
        in: scratch, actor: Self.targetActor)
      #expect(unknown.termination == .exit(2))
      #expect(
        try TaskStateCommandTests.error(unknown)["next"] as? [String] == [
          "silta --ws 'acme' ws show"
        ])
      try Self.changeDefaultAndRejectAudit(fixture.store)
      let args = [
        "--ws", "acme", "task", "edit", "AC-1", "--app", "web",
        "--approved", "Move the Acme release.", "--json",
      ]
      let before = try Self.auditSnapshot(fixture.store)
      let otherCWD = scratch.appending(path: "elsewhere")
      let failed = try Self.run(args, in: scratch, cwd: otherCWD, actor: Self.targetActor)
      #expect(failed.termination != .exit(0))
      #expect(try Self.auditSnapshot(fixture.store) == before)
      try fixture.store.write { try $0.database.execute(sql: "DROP TRIGGER reject_acme_retag") }
      let saved = try Self.run(args, in: scratch, cwd: otherCWD, actor: Self.targetActor)
      try #require(saved.termination == .exit(0), "\(saved.stdout)\(saved.stderr)")
      try Self.checkConsent(fixture.store, before: before, in: scratch)
    }
  }

  @Test func distinguishesNonCodeWorkFromAnAdmittedLegacyApp() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.fixture(scratch)
      try Self.addTasks(fixture, in: scratch)
      let legacy = try Self.run(["task", "edit", "AC-1", "--app", "app:none"], in: scratch)
      try #require(legacy.termination == .exit(0), "\(legacy.stderr)")
      #expect(legacy.stdout.contains("app:api -> app:none"))
      let stillCode = try Self.task("AC-1", in: scratch)
      #expect(stillCode["app"] as? String == "none")
      #expect(stillCode["branch"] as? String == "main")
      let removed = try Self.run(["task", "edit", "AC-1", "--app", "none"], in: scratch)
      try #require(removed.termination == .exit(0), "\(removed.stderr)")
      #expect(removed.stdout == "AC-1 app:none -> none\n")
      let nonCode = try Self.task("AC-1", in: scratch)
      for key in ["app", "branch", "worktree"] { #expect(nonCode[key] == nil) }
      let changes = try fixture.store.read { db in try Self.history(db) }
      #expect(changes == ["app:api -> app:none", "app:none -> none"])
    }
  }

  @Test func rejectsForeignClaimsClosedTasksAndCombinedEditModes() throws {
    try withScratchDirectory { scratch in
      let fixture = try Self.fixture(scratch)
      try Self.addTasks(fixture, in: scratch)
      let before = try Self.auditSnapshot(fixture.store)
      let base = ["task", "edit", "AC-1", "--app", "web", "--json"]
      let foreign = try Self.run(
        base + ["--approved", "Move the Acme release."], in: scratch, actor: Self.targetActor)
      #expect(try TaskStateCommandTests.error(foreign)["code"] as? String == "claimed")
      for flags in [["--print"], ["-F", "absent.md"], ["--allow-secret"]] {
        let mixed = try Self.run(base + flags, in: scratch)
        #expect(mixed.termination == .exit(1))
        #expect(try TaskStateCommandTests.error(mixed)["code"] as? String == "invalid")
      }
      #expect(try Self.auditSnapshot(fixture.store) == before)
      try Self.checkTerminalRefusals(fixture.store, in: scratch)
    }
  }

}

extension TaskAppEditCommandTests {
  private struct Fixture {
    let store: DatabaseStore
    let source: URL
    let target: URL
  }

  private static func fixture(_ scratch: URL) throws -> Fixture {
    let store = try TaskCommandTests.setup(scratch)
    let yaml = """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}, {slug: website}]
      apps:
        - {slug: api, repo: platform, ref: main}
        - {slug: desk, repo: platform, ref: desk}
        - {slug: web, repo: website, ref: main}
      """
    try AcmeDocAttachments.apply(yaml, to: store)
    let source = scratch.appending(path: "platform")
    let target = scratch.appending(path: "website")
    try InitCommandTests.makeRepo(source, in: scratch)
    try InitCommandTests.makeRepo(target, in: scratch)
    try InitCommandTests.commit(target, "Different Acme repository", in: scratch)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO repo_path(repo_id,path) SELECT id,:source FROM repo WHERE slug='platform';
          INSERT INTO repo_path(repo_id,path) SELECT id,:target FROM repo WHERE slug='website';
          INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
            SELECT 'legacy-app',workspace_id,'none','Legacy App',repo_id,'legacy'
            FROM app WHERE slug='api';
          UPDATE app SET previous_slugs='["legacy-web"]' WHERE slug='web';
          INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
          """, arguments: ["source": source.path, "target": target.path])
    }
    return Fixture(store: store, source: source, target: target)
  }

  private static func addTasks(_ f: Fixture, in scratch: URL) throws {
    for (args, directory) in [
      (
        ["Retag Acme release", "--start", "--app", "api", "-m", "Preserve Acme evidence."],
        f.source
      ),
      (["Acme existing child", "--parent", "AC-1"], f.source),
      (["Acme other app child", "--parent", "AC-1", "--app", "web"], f.target),
    ] {
      let result = try run(["task", "add"] + args, in: scratch, cwd: directory)
      try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    }
  }

  private static func checkAfterMove(in scratch: URL) throws {
    let moved = try task("AC-1", in: scratch)
    #expect(moved["app"] as? String == "web")
    #expect(moved["branch"] == nil && moved["worktree"] == nil)
    #expect(moved["claimed_by"] as? String == sourceActor["SILTA_ACTOR"])
    let sourceChild = try task("AC-2", in: scratch)
    let targetChild = try task("AC-3", in: scratch)
    #expect(sourceChild["app"] as? String == "api")
    #expect(targetChild["app"] as? String == "web")
    for (app, expected) in [("api", ["AC-2"]), ("desk", []), ("web", ["AC-1", "AC-3"])] {
      let listed = try run(["task", "ls", "--app", app, "--json"], in: scratch)
      let refs = try TaskStateCommandTests.tasks(listed).compactMap { $0["ref"] as? String }
      #expect(refs == expected)
    }
  }

  private static func resumeAndFinish(_ f: Fixture, in scratch: URL) throws {
    let brief = try run(["brief", "--json"], in: scratch, cwd: f.target, actor: targetActor)
    #expect(brief.termination == .exit(0))
    #expect(brief.stdout.contains("Retag Acme release"))
    let start = ["task", "start", "AC-1", "--json"]
    let denied = try run(start, in: scratch, cwd: f.target, actor: targetActor)
    #expect(try TaskStateCommandTests.error(denied)["code"] as? String == "claimed")
    let handoff = try run(
      ["comment", "AC-1", "--kind", "handoff", "-m", "Continue in the Acme website repo."],
      in: scratch, cwd: f.source)
    try #require(handoff.termination == .exit(0), "\(handoff.stderr)")
    let started = try run(start, in: scratch, cwd: f.target, actor: targetActor)
    try #require(started.termination == .exit(0), "\(started.stdout)\(started.stderr)")
    let resumed = try task("AC-1", in: scratch)
    let recorded = try #require(resumed["worktree"] as? String)
    #expect(
      URL(filePath: recorded).resolvingSymlinksInPath().path
        == f.target.resolvingSymlinksInPath().path)
    let done = try run(
      ["task", "done", "AC-1", "-m", "Released the Acme website.", "--json"],
      in: scratch, cwd: f.target, actor: targetActor)
    try #require(done.termination == .exit(0), "\(done.stdout)\(done.stderr)")
    let targetHead = try String(
      contentsOf: f.target.appending(path: ".git/refs/heads/main"), encoding: .utf8)
    #expect(
      try task("AC-1", in: scratch)["done_sha"] as? String
        == targetHead.trimmingCharacters(in: .newlines))
  }

  private static func changeDefaultAndRejectAudit(_ store: DatabaseStore) throws {
    try store.write { tx in
      try tx.database.execute(
        sql: """
          UPDATE meta SET value='beta' WHERE key='current_workspace';
          CREATE TRIGGER reject_acme_retag BEFORE INSERT ON approval
          WHEN NEW.command LIKE '%task edit%'
          BEGIN SELECT RAISE(ABORT,'fixture refuses consent'); END;
          """)
    }
  }

  private static func checkConsent(
    _ store: DatabaseStore, before: [[Row]], in scratch: URL
  ) throws {
    let after = try auditSnapshot(store)
    #expect(after[1].count == before[1].count + 1)
    #expect(after[2].count == before[2].count + 1)
    #expect(after[2].last?["workspace"] as? String == "acme")
    #expect(after[2].last?["words"] as? String == "Move the Acme release.")
    #expect(try store.read { db in try history(db) } == ["app:api -> app:web"])
    let repeatMove = try run(
      [
        "--ws", "acme", "task", "edit", "AC-1", "--app", "legacy-web", "--approved",
        "Move the Acme release.", "--json",
      ], in: scratch, actor: targetActor)
    try #require(repeatMove.termination == .exit(0), "\(repeatMove.stdout)\(repeatMove.stderr)")
    #expect(try TaskStateCommandTests.data(repeatMove)["app_change"] == nil)
    #expect(Set(try TaskStateCommandTests.warnings(repeatMove)) == ["renamed", "approval_unused"])
    #expect(try auditSnapshot(store) == after)
  }

  private static func checkTerminalRefusals(_ store: DatabaseStore, in scratch: URL) throws {
    for status in ["done", "dropped", "promoted"] {
      try store.write { tx in
        try tx.database.execute(
          sql: """
            UPDATE task SET status=?,external_ref=?,claimed_by=NULL,claimed_at=NULL WHERE seq=1
            """,
          arguments: [
            status == "promoted" ? "todo" : status,
            status == "promoted" ? "ado:1" : nil,
          ])
      }
      let before = try auditSnapshot(store)
      let result = try run(
        ["task", "edit", "AC-1", "--app", "web", "--approved", "Retag Acme.", "--json"],
        in: scratch)
      let code = try TaskStateCommandTests.error(result)["code"] as? String
      #expect(code == (status == "promoted" ? "read_only_promoted" : "conflict"))
      #expect(try auditSnapshot(store) == before)
    }
  }

  private static func history(_ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT body FROM task_event WHERE kind='field' ORDER BY id")
  }

  private static func auditSnapshot(_ store: DatabaseStore) throws -> [[Row]] {
    try store.read { db in
      [
        try Row.fetchAll(db, sql: "SELECT * FROM task ORDER BY id"),
        try Row.fetchAll(db, sql: "SELECT * FROM task_event ORDER BY id"),
        try Row.fetchAll(db, sql: "SELECT * FROM approval ORDER BY id"),
      ]
    }
  }

  private static func task(_ ref: String, in scratch: URL) throws -> [String: Any] {
    try TaskStateCommandTests.data(
      run(["--ws", "acme", "task", "show", ref, "--json"], in: scratch))
  }

  private static func run(
    _ args: [String], in scratch: URL, cwd: URL? = nil,
    actor: [String: String] = sourceActor
  ) throws -> CLIResult {
    try SiltaBinary.run(args, in: scratch, cwd: cwd, environment: actor)
  }
}
