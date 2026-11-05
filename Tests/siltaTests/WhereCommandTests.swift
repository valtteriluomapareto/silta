import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(3)))
struct WhereCommandTests {
  @Test func fixtureBranchesAndPromotionChain() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      for (branch, app, reason) in [
        ("master", "platform", "exact_ref"), ("api", "api", "exact_ref"),
        ("api-prod", "api", "exact_ref"), ("portal-prod", "portal", "exact_ref"),
        ("renamed", "platform", "reflog"), ("rebased", "portal", "reflog"),
        ("non-app", "platform", "reflog"), ("from-non-app", "", "distance"),
      ] {
        try git(["checkout", "-q", branch], repo, scratch)
        let result = try run([], repo, scratch)
        let data = try data(result)
        #expect(data["reason"] as? String == reason, "\(branch): \(result.stdout)")
        #expect(data["app"] as? String == (app.isEmpty ? nil : app))
      }
      let portal = scratch.appending(path: "fixtures/acme-portal-worktree")
      #expect(try data(run([], portal, scratch))["app"] as? String == "portal")
      try git(["checkout", "-q", "api"], repo, scratch)
      let result = try run([], repo, scratch)
      Golden.forTests().check(result.stdout, "where.json")
      let text = try SiltaBinary.run(["where", "--quiet"], in: scratch, cwd: repo)
      Golden.forTests().check(text.stdout, "where.txt")
      #expect(text.stderr.isEmpty)
    }
  }

  @Test func subpathsCanonicalAliasesAndUnregisteredPaths() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let console = repo.appending(path: "apps/console")
      #expect(try data(run([], console, scratch))["app"] as? String == "console")
      let sibling = repo.appending(path: "apps/console-other")
      try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
      #expect(try data(run([], sibling, scratch))["app"] as? String == "api")
      let alias = scratch.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: console)
      #expect(try run([], alias, scratch).stdout == run([], console, scratch).stdout)
      let unregistered = try run([], scratch.appending(path: "fixtures/acme-detached"), scratch)
      #expect(unregistered.termination == .exit(2))
      let unregisteredPath = scratch.appending(path: "fixtures/acme-detached").path
      let normalized = unregistered.stdout.replacingOccurrences(
        of: unregisteredPath, with: "<path>"
      )
      .replacingOccurrences(of: unregisteredPath.lowercased(), with: "<path>")
      Golden.forTests().check(normalized, "where-unregistered.json")
      let outside = try run([], scratch, scratch)
      #expect(outside.termination == .exit(2))
    }
  }

  @Test func detachedShallowMissingRefsAndDistance() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["checkout", "-q", "--detach", "api"], repo, scratch)
      let detached = try run([], repo, scratch)
      let value = try data(detached)
      #expect(value["branch"] is NSNull)
      #expect(value["reason"] as? String == "distance")
      #expect(value["app"] as? String == "api")
      Golden.forTests().check(detached.stdout, "where-detached.json")
      try git(["update-ref", "-d", "refs/remotes/origin/portal"], repo, scratch)
      let missing = try run([], repo, scratch)
      #expect(missing.stdout.contains("ref_missing"))
      #expect(try data(missing)["app"] == nil)
      #expect(try data(missing)["confidence"] as? String == "low")
      let shallow = scratch.appending(path: "fixtures/acme-shallow")
      let store = store(scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE repo_path SET path=?", arguments: [shallow.path])
      }
      #expect(try data(run([], shallow, scratch))["reason"] as? String == "exact_ref")
      try git(["update-ref", "refs/remotes/origin/portal", "HEAD"], shallow, scratch)
      try git(["checkout", "-q", "--detach"], shallow, scratch)
      let incomplete = try data(run([], shallow, scratch))
      #expect(incomplete["confidence"] as? String == "low")
      #expect(incomplete["reason"] as? String == "shallow")
      #expect(incomplete["app"] == nil)
    }
  }

  @Test func taskAndOverridePrecedenceAndApprovalAtomicity() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let store = store(scratch)
      try store.write { tx in
        for (seq, app, actor, branch) in [
          (1, "portal", "agent:codex:acme", "other"),
          (2, "api", "agent:codex:other", "api"),
        ] {
          try tx.database.execute(
            sql: """
              INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,
                claimed_at,branch,created_by,created_at,updated_at)
              SELECT ?,workspace_id,?,'Acme','doing',id,?,'2023-11-14T22:13:20.000Z',?,
                'human:acme','2023-11-14T22:13:20.000Z','2023-11-14T22:13:20.000Z'
              FROM app WHERE slug=?
              """, arguments: ["task-\(seq)", seq, actor, branch, app])
        }
      }
      #expect(try data(run([], repo, scratch))["app"] as? String == "portal")
      #expect(try data(run(["--task", "AC-2"], repo, scratch))["app"] as? String == "api")
      let refusal = try run(["--set", "platform"], repo, scratch)
      #expect(refusal.termination == .exit(3))
      let normalized = refusal.stdout.replacingOccurrences(of: repo.path, with: "<path>")
        .replacingOccurrences(of: repo.path.lowercased(), with: "<path>")
      Golden.forTests().check(normalized, "where-human-only.json")
      #expect(refusal.stdout.contains("--path"))
      #expect(refusal.stdout.contains("--ws"))
      #expect(try counts(store) == [0, 0])
      let approved = try run(
        ["--path", repo.path, "--set", "platform", "--approved", "Yes, set this override"],
        scratch, scratch)
      #expect(approved.termination == .exit(0), "\(approved.stdout)")
      #expect(try counts(store) == [1, 1])
      #expect(try data(run([], repo, scratch))["reason"] as? String == "override")
      #expect(try data(run(["--app", "api"], repo, scratch))["app"] as? String == "api")
      #expect(try run(["--unset"], repo, scratch).termination == .exit(3))
      let unset = try run(["--unset", "--approved", "Yes, remove the override"], repo, scratch)
      #expect(unset.termination == .exit(0))
      #expect(try counts(store) == [0, 2])
      #expect(try data(run([], repo, scratch))["app"] as? String == "portal")
      let invalid = try run(["--set", "absent", "--approved", "Yes"], repo, scratch)
      #expect(invalid.termination == .exit(2))
      #expect(try counts(store) == [0, 2])
      #expect(try run(["--app", "console"], repo, scratch).termination == .exit(4))
    }
  }

  @Test func cacheIsDerivedNonblockingAndSensitiveToHeadAndRefs() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["checkout", "-q", "--detach", "api"], repo, scratch)
      let store = store(scratch)
      let before = try store.read {
        try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='change_seq'")
      }
      let first = try run([], repo, scratch)
      let index = scratch.appending(path: "silta-home/index.db")
      #expect(FileManager.default.fileExists(atPath: index.path))
      let queue = try DatabaseQueue(path: index.path)
      try queue.writeWithoutTransaction { db in
        try db.execute(sql: "BEGIN EXCLUSIVE")
        defer { try? db.execute(sql: "ROLLBACK") }  // best-effort lock release
        // WallClockWhereTests proves the locked read doesn't wait.
        let locked = try run([], repo, scratch)
        #expect(locked.termination == .exit(0))
        #expect(locked.stdout == first.stdout)
      }
      try git(["checkout", "-q", "--detach", "portal"], repo, scratch)
      #expect(try data(run([], repo, scratch))["app"] as? String == "portal")
      try git(["update-ref", "refs/remotes/origin/api", "portal"], repo, scratch)
      let tied = try data(run([], repo, scratch))
      #expect(tied["confidence"] as? String == "low")
      #expect(tied["app"] == nil)
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='change_seq'")
        } == before)
      try FileManager.default.removeItem(at: index)
      try Data("corrupt".utf8).write(to: index)
      #expect(try run([], repo, scratch).termination == .exit(0))
    }
  }

  @Test func upstreamReflogBranchTasksAndSingleCandidateOrder() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["checkout", "-qb", "topic", "master"], repo, scratch)
      try git(["branch", "--set-upstream-to=origin/api", "topic"], repo, scratch)
      #expect(try data(run([], repo, scratch))["reason"] as? String == "upstream")
      #expect(try data(run([], repo, scratch))["app"] as? String == "api")
      try git(["branch", "--unset-upstream", "topic"], repo, scratch)
      #expect(try data(run([], repo, scratch))["app"] as? String == "platform")
      try FileManager.default.removeItem(at: repo.appending(path: ".git/logs/refs/heads/topic"))
      #expect(try data(run([], repo, scratch))["reason"] as? String == "distance")
      let store = store(scratch)
      try store.write {
        try $0.database.execute(sql: "DELETE FROM app WHERE slug NOT IN ('api','console')")
        try $0.database.execute(
          sql: """
            INSERT INTO worktree_override(path,app_id,set_by)
            SELECT ?,id,'human:acme' FROM app WHERE slug='console'
            """, arguments: [repo.path.lowercased()])
      }
      let single = try data(run([], repo, scratch))
      #expect(single["app"] as? String == "api")
      #expect(single["reason"] as? String == "single")
      try Data("broken\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      #expect(try run([], repo, scratch).termination == .exit(9))
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func locationScenarioSurvivesRestart() throws {
    try withScratchDirectory { scratch in
      _ = try ScenarioRunner.run(
        ScenarioRunner.repository.appending(path: "Tests/Scenarios/location.yaml"), in: scratch)
    }
  }

  func setup(_ scratch: URL) throws -> URL {
    let fixture = try AcmeFixtures.make(at: scratch.appending(path: "fixtures"))
    try #require(fixture.termination == .exit(0), "\(fixture.stderr)")
    let repo = scratch.appending(path: "fixtures/acme-platform")
    let config = try WorkspaceConfig.parse(
      """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps:
        - {slug: platform, repo: platform, ref: origin/master}
        - {slug: portal, repo: platform, ref: origin/portal, prod_ref: origin/portal-prod}
        - {slug: api, repo: platform, ref: origin/api, prod_ref: origin/api-prod}
        - {slug: console, repo: platform, ref: origin/api, subpath: apps/console}
      """)
    let store = store(scratch)
    try store.write {
      try config.apply(
        in: $0, ids: SeededIDGenerator(seed: 1), at: Date(timeIntervalSince1970: 1_700_000_000))
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [repo.path])
    }
    try WorkspaceSelection.use("acme", in: store)
    return repo
  }

  func run(_ args: [String], _ cwd: URL, _ scratch: URL, timeout: Double = 30) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme", "where", "--json"] + args, in: scratch, cwd: cwd,
      environment: ["SILTA_ACTOR": "agent:codex:acme"], timeout: timeout)
  }

  func git(_ args: [String], _ repo: URL, _ scratch: URL) throws {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: repo)
    try #require(result.termination == .exit(0), "\(result.stderr)")
  }

  func data(_ result: CLIResult) throws -> [String: Any] {
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    let envelope = try #require(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    return try #require(envelope["data"] as? [String: Any])
  }

  private func store(_ scratch: URL) -> DatabaseStore {
    DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
  }

  private func counts(_ store: DatabaseStore) throws -> [Int] {
    try store.read { db in
      try ["worktree_override", "approval"].map {
        try #require(try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)"))
      }
    }
  }
}

extension WhereCommandTests {
  @Test func delayedCheckoutUsesDistanceInsteadOfLaterCheckoutOrigin() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["checkout", "-qB", "release/acme", "master"], repo, scratch)
      try git(["branch", "delayed-topic", "HEAD"], repo, scratch)
      try git(["checkout", "-q", "master"], repo, scratch)
      try git(["checkout", "-q", "delayed-topic"], repo, scratch)
      let result = try data(run([], repo, scratch))
      #expect(result["confidence"] as? String == "high")
      #expect(result["app"] as? String == "platform")
      #expect(result["reason"] as? String == "distance")
    }
  }

  @Test func unrelatedCorruptionDoesNotPoisonRegisteredMatch() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let broken = scratch.appending(path: "fixtures/acme-detached")
      try store(scratch).write {
        try $0.database.execute(
          sql: """
            INSERT INTO repo(id,uid,workspace_id,slug) VALUES(0,'broken',1,'broken');
            INSERT INTO repo_path(repo_id,path) VALUES(0,?);
            """, arguments: [broken.path])
      }
      try Data("broken\n".utf8).write(to: broken.appending(path: ".git/HEAD"))
      #expect(try run([], repo, scratch).termination == .exit(0))
      #expect(try run([], broken, scratch).termination == .exit(9))
    }
  }

  @Test func implicitCreationWithoutNamedEvidenceUsesDistance() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["checkout", "-qB", "release/acme", "master"], repo, scratch)
      try git(["checkout", "-qb", "implicit-topic"], repo, scratch)
      let result = try data(run([], repo, scratch))
      #expect(result["confidence"] as? String == "high")
      #expect(result["reason"] as? String == "distance")
      #expect(result["app"] as? String == "platform")
    }
  }

  @Test func missingRefsDoNotCreateFalseSingleCandidates() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["update-ref", "-d", "refs/remotes/origin/portal"], repo, scratch)
      let attached = try run([], repo, scratch)
      #expect(attached.stdout.contains("ref_missing"))
      try git(["update-ref", "-d", "refs/remotes/origin/api"], repo, scratch)
      let result = try data(run([], repo, scratch))
      #expect(result["app"] == nil)
      #expect(result["confidence"] as? String == "low")
      #expect(result["reason"] as? String == "distance")
      #expect((result["candidates"] as? [[String: String]])?.count == 3)
    }
  }

  @Test func crossRepoAppSelectionsOfferCurrentPathCandidates() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let store = store(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO repo(id,uid,workspace_id,slug) VALUES(2,'neighbor',1,'neighbor');
            INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
            VALUES('neighbor-app',1,'neighbor','Acme Neighbor',2,'main');
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,
              created_by,created_at,updated_at)
            SELECT 'neighbor-task',1,1,'Acme','todo',id,'human:acme','',''
            FROM app WHERE slug='neighbor';
            """)
      }
      for args in [["--app", "neighbor"], ["--task", "AC-1"], ["--set", "neighbor"]] {
        let result = try run(args, repo, scratch)
        #expect(result.termination == .exit(4), "\(result.stdout)")
        #expect(result.stdout.contains("--path"))
        #expect(result.stdout.contains("--app 'api'"))
      }
      #expect(try counts(store) == [0, 0])
    }
  }

  @Test func liveTaskEvidenceAndOverridesBeatAWarmDistanceCache() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["checkout", "-q", "--detach", "api"], repo, scratch)
      #expect(try data(run([], repo, scratch))["reason"] as? String == "distance")
      let store = store(scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,
              created_by,created_at,updated_at)
            SELECT 'portal-task',1,1,'Acme','doing',id,'agent:codex:acme','human:acme','',''
            FROM app WHERE slug='portal';
            """)
      }
      #expect(try data(run([], repo, scratch))["app"] as? String == "portal")
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,app_id,claimed_by,
              created_by,created_at,updated_at)
            SELECT 'api-task',1,2,'Acme','doing',id,'agent:codex:acme','human:acme','',''
            FROM app WHERE slug='api';
            """)
      }
      #expect(try data(run([], repo, scratch))["reason"] as? String == "task")
      #expect(try data(run([], repo, scratch))["app"] as? String == "api")
      try git(["checkout", "-q", "api"], repo, scratch)
      try store.write {
        try $0.database.execute(
          sql: """
            UPDATE task SET claimed_by='agent:codex:other',
              branch=CASE WHEN seq=1 THEN 'api' ELSE NULL END;
            """)
      }
      #expect(try data(run([], repo, scratch))["app"] as? String == "portal")
      try store.write { try $0.database.execute(sql: "UPDATE task SET branch='api'") }
      #expect(try data(run([], repo, scratch))["reason"] as? String == "task")
      _ = try data(run(["--set", "platform", "--approved", "Yes, use platform"], repo, scratch))
      try git(["checkout", "-q", "--detach", "api"], repo, scratch)
      #expect(try data(run([], repo, scratch))["reason"] as? String == "override")
    }
  }

  @Test func noCandidateAppsOffersConfigurationRecovery() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try store(scratch).write { try $0.database.execute(sql: "DELETE FROM app") }
      let result = try SiltaBinary.run(["--ws", "acme", "where"], in: scratch, cwd: repo)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.hasSuffix("next: silta --ws 'acme' ws show\n"))
    }
  }

}
