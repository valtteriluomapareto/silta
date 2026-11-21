import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct WorkspaceRemovalCommandTests {
  @Test func humanRemovalBacksUpTheTargetAndLeavesTheOtherWorkspaceIntact() throws {
    try withScratchDirectory { scratch in
      let (store, repo) = try Self.fixture(scratch)
      let acme = try Self.export("acme", to: "before-acme", in: scratch)
      let beta = try Self.export("beta", to: "before-beta", in: scratch)
      let preview = try Self.run(["ws", "rm", "acme", "--dry-run", "--json"], in: scratch)
      try #require(preview.termination == .exit(0), "\(preview.stdout)\(preview.stderr)")
      try Self.checkPreview(preview)
      #expect(try Self.export("acme", to: "before-acme", in: scratch) == acme)
      let refused = try Self.run(
        ["ws", "rm", "acme", "--allow-active", "--approved", "Remove Acme", "--json"],
        in: scratch)
      #expect(refused.termination == .exit(3))
      let rejection = try TaskStateCommandTests.error(refused)
      #expect(rejection["code"] as? String == "human_only")
      #expect(rejection["next_by"] as? String == "human")
      #expect((rejection["next"] as? [String])?.allSatisfy { !$0.contains("--approved") } == true)
      let active = try Self.human(["ws", "rm", "acme", "--json"], in: scratch)
      #expect(active.termination == .exit(6))
      let removed = try Self.human(["ws", "rm", "acme", "--allow-active", "--json"], in: scratch)
      try #require(removed.termination == .exit(0), "\(removed.stdout)")
      let receipt = try TaskStateCommandTests.data(removed)
      try Self.checkSQLiteBackup(receipt, repo: repo)
      #expect(FileManager.default.fileExists(atPath: repo.appending(path: ".git").path))
      try Self.checkRemoval(store)
      #expect(try Self.export("beta", to: "after-beta", in: scratch) == beta)
      try Self.recover(receipt, target: acme, in: scratch)
    }
  }

  @Test func refusedRecoveryAdmissionAndLateSQLiteFailureNeverCommitRemoval() throws {
    try withScratchDirectory { scratch in
      let (store, _) = try Self.fixture(scratch)
      let before = try Self.export("acme", to: "before-failure", in: scratch)
      try store.write {
        try $0.database.execute(
          sql: #"UPDATE workspace SET settings='{"future":42}' WHERE slug='acme'"#)
      }
      let unsafe = try Self.human(["ws", "rm", "acme", "--allow-active", "--json"], in: scratch)
      #expect(unsafe.termination == .exit(1))
      #expect(unsafe.stdout.contains("future"))
      #expect(
        try TaskStateCommandTests.error(unsafe)["next"] as? [String] == [
          "silta --ws 'acme' ws show"
        ])
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE workspace SET settings='{}' WHERE slug='acme';
            CREATE TRIGGER acme_fixture_rollback BEFORE DELETE ON workspace
            WHEN OLD.slug='acme' BEGIN SELECT RAISE(ABORT, 'fixture rejects deletion'); END;
            """)
      }
      let failed = try Self.human(["ws", "rm", "acme", "--allow-active", "--json"], in: scratch)
      #expect(failed.termination == .exit(9))
      #expect(
        try TaskStateCommandTests.error(failed)["message"] as? String
          == StorageError.constraintViolation.message)
      #expect(try Self.export("acme", to: "after-failure", in: scratch) == before)
      try store.read { (db: Database) throws in
        #expect(
          try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='current_workspace'")
            == "acme")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM repo_path") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM worktree_override") == 1)
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM task WHERE claimed_by IS NOT NULL") == 1)
      }
    }
  }

  @Test func previewRequiresAnExactTargetAndNeverCreatesStorage() throws {
    try withScratchDirectory { scratch in
      let missing = try Self.run(["ws", "rm", "acme", "--dry-run", "--json"], in: scratch)
      #expect(missing.termination == .exit(2))
      let mismatch = try Self.run(
        ["--ws", "beta", "ws", "rm", "acme", "--dry-run", "--json"], in: scratch)
      #expect(mismatch.termination == .exit(1))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }

  @Test func previewOfAnEmptyWorkspaceMatchesItsPublishedShape() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(id,uid,slug,name,task_prefix)
              VALUES(10,'ws-empty','empty','Empty','EM');
            """)
      }
      let preview = try Self.run(["ws", "rm", "empty", "--dry-run", "--json"], in: scratch)
      #expect(preview.termination == .exit(0))
      Golden.forTests().check(preview.stdout, "ws-rm-preview.json")
    }
  }

  private static func checkPreview(_ result: CLIResult) throws {
    let data = try TaskStateCommandTests.data(result)
    #expect(data["dry_run"] as? Bool == true)
    let counts = try #require(data["counts"] as? [[String: Any]])
    for kind in ["task", "claim", "doc", "doc_rev", "repo", "app", "approval", "worktree_override"]
    {
      #expect(counts.first { $0["kind"] as? String == kind }?["count"] as? Int == 1)
    }
    #expect(data["saved_default"] as? Bool == true)
    #expect((data["registered_clones"] as? [String])?.count == 1)
    #expect(!(result.stdout + result.stderr).contains("\u{1B}"))
  }

  private static func checkSQLiteBackup(_ receipt: [String: Any], repo: URL) throws {
    let path = try #require(receipt["backup"] as? String)
    var options = Configuration()
    options.readonly = true
    let queue = try DatabaseQueue(path: path, configuration: options)
    try queue.read { (db: Database) throws in
      #expect(try String.fetchOne(db, sql: "SELECT path FROM repo_path") == repo.path)
      #expect(try String.fetchOne(db, sql: "SELECT path FROM worktree_override") == repo.path)
      #expect(
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='current_workspace'")
          == "acme")
      #expect(try String.fetchOne(db, sql: "SELECT claimed_by FROM task") == "agent:codex:acme")
      #expect(
        try Int.fetchOne(db, sql: "SELECT count(*) FROM approval WHERE workspace='acme'") == 1)
    }
  }

  private static func checkRemoval(_ store: DatabaseStore) throws {
    try store.read { (db: Database) throws in
      #expect(try String.fetchAll(db, sql: "SELECT slug FROM workspace") == ["beta"])
      #expect(
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key='current_workspace'") == nil)
      #expect(
        try String.fetchAll(db, sql: "SELECT scope FROM seq_counter ORDER BY scope") == ["task:10"])
      for table in [
        "repo", "app", "doc", "doc_rev", "task", "approval", "worktree_override", "repo_path",
      ] {
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0, "\(table)")
      }
    }
  }

  private static func recover(_ data: [String: Any], target: [String: Data], in scratch: URL) throws
  {
    let changed = try run(
      ["--ws", "beta", "task", "add", "Bystander work", "--app", "none"], in: scratch)
    try #require(changed.termination == .exit(0), "\(changed.stderr)")
    let beta = try export("beta", to: "newer-beta", in: scratch)
    let hint = try #require((data["next"] as? [String])?.first)
    let preview = try FirstWorkspaceCommandTests.replay(hint, in: scratch, cwd: scratch)
    #expect(preview.termination == .exit(0), "\(hint) \(preview.stderr)")
    let recovery = try #require(data["recovery"] as? String)
    let restored = try human(["--ws", "acme", "restore", recovery, "--json"], in: scratch)
    try #require(restored.termination == .exit(0), "\(restored.stdout)")
    #expect(try export("acme", to: "restored-acme", in: scratch) == target)
    #expect(try export("beta", to: "restored-beta", in: scratch) == beta)
  }

  private static func fixture(_ scratch: URL) throws -> (DatabaseStore, URL) {
    let store = try AcmeDocAttachments.make(in: scratch)
    try AcmeDocAttachments.attach("rules", to: "app", in: store)
    let repo = scratch.appending(path: "platform")
    try InitCommandTests.makeRepo(repo, in: scratch)
    try store.write { tx in
      try tx.database.execute(
        sql: "UPDATE workspace SET name=? WHERE slug='acme'",
        arguments: ["Acme\u{1b} \u{202e}Operations"])
      try tx.database.execute(
        sql: """
          INSERT INTO workspace(id,uid,slug,name,task_prefix)
            VALUES(10,'ws-beta','beta','Beta','BE');
          INSERT INTO meta(key,value) VALUES('current_workspace','acme');
          INSERT INTO repo_path(repo_id,path) SELECT id,:path FROM repo;
          INSERT INTO worktree_override(path,app_id,set_by) SELECT :path,id,'human:acme' FROM app;
          INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,claimed_at,
            created_by,created_at,updated_at,branch,worktree)
          SELECT 'task-acme',workspace_id,1,'Acme work','doing',id,'agent:codex:acme',:now,
            'agent:codex:acme',:now,:now,'main',:path FROM app;
          INSERT INTO seq_counter(scope,next)
          VALUES('task:1',2),('task:10',1),('doc_rev:1:archived',3);
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
          VALUES('acme-approval','acme','agent:codex:acme','silta ws edit','Create Acme',:now);
          """, arguments: ["path": repo.path, "now": "2023-11-14T22:13:20.000Z"])
    }
    return (store, repo)
  }

  private static func export(_ slug: String, to root: String, in scratch: URL) throws -> [String:
    Data]
  {
    let result = try run(["--ws", slug, "export", "--to", root], in: scratch)
    try #require(result.termination == .exit(0), "\(result.stderr)")
    let dir = scratch.appending(path: "work/\(root)/\(slug)")
    let paths = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
    return try paths.reduce(into: [:]) { files, path in
      let url = dir.appending(path: path)
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files[path] = try Data(contentsOf: url)
      }
    }
  }

  private static func human(_ args: [String], in scratch: URL) throws -> CLIResult {
    try EditorTerminalFixture.run(
      args, in: scratch,
      environment: [
        "SILTA_ACTOR": "human:acme", "USER": "acme",
        "SILTA_NOW": "2023-11-14T22:13:20.000Z",
      ]
    ).result
  }

  private static func run(_ args: [String], in scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
  }
}

extension WorkspaceRemovalCommandTests {
  @Test func successfulTextWithAnUnsafeHomePrintsAReplayableRecoveryPreview() throws {
    try withScratchDirectory { root in
      let scratch = root.appending(path: "Acme\nrecovery")
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      _ = try TaskCommandTests.setup(scratch)
      let result = try Self.human(["ws", "rm", "acme", "--allow-active"], in: scratch)
      try #require(result.termination == .exit(0), "\(result.stdout)")
      let line = try #require(result.stdout.split(separator: "\n").first { $0.hasPrefix("next: ") })
      let hint = String(line.dropFirst("next: ".count))
      #expect(hint.contains("$" + "{SILTA_HOME:-$HOME/.silta}"))
      #expect(!hint.contains(scratch.path))
      let preview = try FirstWorkspaceCommandTests.replay(
        hint, in: scratch, cwd: scratch, json: true)
      try #require(preview.termination == .exit(0), "\(preview.stdout)")
      #expect(try TaskStateCommandTests.data(preview)["created"] as? Bool == true)
    }
  }

  @Test func removalAndRecoveryPreserveAPopulatedBystanderAndAQuestion() throws {
    try withScratchDirectory { scratch in
      let (store, _) = try Self.fixture(scratch)
      try Self.populateBeta(store)
      for (workspace, ref) in [("acme", "AC-1"), ("beta", "BE-1")] {
        let asked = try Self.run(
          [
            "--ws", workspace, "comment", ref, "--kind", "question", "-m",
            "@me Check Acme evidence?",
          ],
          in: scratch)
        try #require(asked.termination == .exit(0), "\(asked.stderr)")
      }
      let beta = try Self.export("beta", to: "populated-beta", in: scratch)
      let local = try Self.betaRegistrations(store)
      let acme = try Self.export("acme", to: "populated-acme", in: scratch)
      let removed = try Self.human(["ws", "rm", "acme", "--allow-active", "--json"], in: scratch)
      try #require(removed.termination == .exit(0), "\(removed.stdout)")
      #expect(try Self.export("beta", to: "after-remove-beta", in: scratch) == beta)
      #expect(try Self.betaRegistrations(store) == local)
      #expect(
        try store.read {
          try String.fetchAll($0, sql: "SELECT task_prefix FROM workspace ORDER BY id")
        } == ["BE"])
      try Self.recover(try TaskStateCommandTests.data(removed), target: acme, in: scratch)
      #expect(try Self.betaRegistrations(store) == local)
    }
  }

  private static func populateBeta(_ store: DatabaseStore) throws {
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO repo(id,uid,workspace_id,slug) VALUES(10,'beta-repo',10,'beta-engine');
          INSERT INTO repo_path(repo_id,path) VALUES(10,'/acme-fixture/beta-engine');
          INSERT INTO app(id,uid,workspace_id,slug,name,repo_id,ref)
            VALUES(10,'beta-app',10,'engine','Beta Engine',10,'main');
          INSERT INTO worktree_override(path,app_id,set_by)
            VALUES('/acme-fixture/beta-engine',10,'human:acme');
          INSERT INTO task(id,uid,workspace_id,seq,title,status,app_id,
            created_by,created_at,updated_at)
            VALUES(10,'beta-task',10,1,'Beta work','todo',10,'human:acme',:now,:now);
          UPDATE seq_counter SET next=2 WHERE scope='task:10';
          INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at)
            VALUES(10,'beta-doc',10,'rules','Beta rules','reference',1,:now,:now);
          INSERT INTO doc_rev(id,uid,doc_id,rev,body_md,state,actor,created_at)
            VALUES(10,'beta-rev',10,1,'Beta guidance.','accepted','human:acme',:now);
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
            VALUES('beta-about',10,'doc',10,'about','app',10,'human:acme',:now);
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
            VALUES('beta-approval','beta','agent:codex:acme','silta ws edit','Create Beta',:now);
          """, arguments: ["now": "2023-11-14T22:13:20.000Z"])
    }
  }

  private static func betaRegistrations(_ store: DatabaseStore) throws -> [Row] {
    try store.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT repo_path.path AS repo,worktree_override.path AS worktree FROM app
          JOIN repo_path ON repo_path.repo_id=app.repo_id
          JOIN worktree_override ON worktree_override.app_id=app.id
          WHERE app.workspace_id=10
          """)
    }
  }
}

extension WorkspaceRemovalCommandTests {
  @Test(arguments: [false, true])
  func brokenGitRegistrationCanOnlyBeRemovedWithAHumanOverride(link: Bool) throws {
    try withScratchDirectory { scratch in
      let (store, _) = try Self.fixture(scratch)
      let path = try Self.addBrokenCheckout(link: link, store: store, in: scratch)
      let command = "silta ws rm 'acme' --allow-active"
      let initial = try Self.export("acme", to: "before-broken", in: scratch)
      try Self.checkBrokenRemovalPreview(path, hint: command, in: scratch)
      #expect(try Self.export("acme", to: "after-refused-broken", in: scratch) == initial)
      let denied = try Self.run(
        ["ws", "rm", "acme", "--allow-active", "--approved", "Remove Acme.", "--json"],
        in: scratch)
      #expect(denied.termination == .exit(3))
      let removed = try Self.human(["ws", "rm", "acme", "--allow-active", "--json"], in: scratch)
      let receipt = try GuideContractTests.object(removed.stdout)["data"] as? [String: Any]
      withKnownIssue(
        "A dangling gitdir file currently blocks the direct human override.", isIntermittent: link
      ) {
        #expect(removed.termination == .exit(0))
        #expect(receipt?["backup"] is String && receipt?["recovery"] is String)
      }
      #expect(FileManager.default.fileExists(atPath: path + "/acme-sentinel"))
      if let receipt {
        try Self.checkRemoval(store)
        try Self.recover(receipt, target: initial, in: scratch)
      }
    }
  }

  private static func addBrokenCheckout(
    link: Bool, store: DatabaseStore, in scratch: URL
  ) throws -> String {
    let path = scratch.appending(path: "Acme broken clone")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    let marker = path.appending(path: ".git")
    let missing = scratch.appending(path: "missing-gitdir")
    if link {
      try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: missing)
    } else {
      try Data(("gitdir: " + missing.path + "\n").utf8).write(to: marker)
    }
    try Data("Acme file".utf8).write(to: path.appending(path: "acme-sentinel"))
    try store.write { tx in
      try tx.database.execute(sql: "UPDATE repo_path SET path=?", arguments: [path.path])
    }
    return path.path
  }

  private static func checkBrokenRemovalPreview(
    _ path: String, hint: String, in scratch: URL
  ) throws {
    let preview = try Self.run(["ws", "rm", "acme", "--dry-run", "--json"], in: scratch)
    let data = try GuideContractTests.object(preview.stdout)["data"] as? [String: Any]
    let text = try Self.run(["ws", "rm", "acme", "--dry-run"], in: scratch)
    let denied = try Self.human(["ws", "rm", "acme", "--json"], in: scratch)
    let error = try TaskStateCommandTests.error(denied)
    withKnownIssue("An unresolved clone currently prevents preview and gives no usable retry.") {
      #expect(preview.termination == .exit(0))
      #expect(data?["unresolved_clones"] as? [String] == [path])
      #expect(data?["next_by"] as? String == "human" && data?["next"] as? [String] == [hint])
      #expect(text.stdout.contains(path) && text.stdout.contains("ask human: " + hint))
      #expect(denied.termination == .exit(9))
      #expect(
        (error["message"] as? String)?.contains(path) == true)
      #expect(error["next_by"] as? String == "human" && error["next"] as? [String] == [hint])
    }
  }
}
