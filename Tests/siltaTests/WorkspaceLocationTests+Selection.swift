import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension WorkspaceLocationTests {
  static func git(_ args: [String], scratch: URL, cwd: URL) throws -> String {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: cwd)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    return result.stdout
  }

  static func disjointWorkspaces(_ scratch: URL) throws -> (URL, DatabaseStore) {
    let repositories = ["acme/frontend", "acme/backend", "beta/backend"]
    for relative in repositories {
      let repo = scratch.appending(path: relative)
      _ = try git(["init", "-q", "--initial-branch=main"], scratch: scratch, cwd: repo)
      let label = relative.hasPrefix("acme/") ? "Acme" : "Beta"
      try "\(label) needle\n".write(
        to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      _ = try git(["add", "README.md"], scratch: scratch, cwd: repo)
      _ = try git(
        [
          "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm",
          "Add needle",
        ], scratch: scratch, cwd: repo)
      _ = try git(
        ["remote", "add", "origin", "https://example.invalid/\(relative).git"],
        scratch: scratch, cwd: repo)
      _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"], scratch: scratch, cwd: repo)
    }
    let identities = try repositories.map {
      try git(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        scratch: scratch, cwd: scratch.appending(path: $0))
    }
    try #require(Set(identities).count == 3)
    for (slug, prefix) in [("acme", "AC"), ("beta", "BE")] {
      let scan = try run(
        [
          "init", "--scan", scratch.appending(path: slug).path,
          "--slug", slug, "--prefix", prefix,
        ], scratch)
      try #require(scan.termination == .exit(0), "\(scan.stdout)\(scan.stderr)")
      try #require(
        try run(["--ws", slug, "task", "add", "\(slug) request", "--start"], scratch)
          .termination == .exit(0))
    }
    try #require(try run(["ws", "use", "beta"], scratch).termination == .exit(0))
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    return (scratch.appending(path: "acme/frontend"), store)
  }

  @Test func repositoryWorkspaceMatchesBriefForCrossRepoReadsAndWrites() throws {
    try withScratchDirectory { scratch in
      let (frontend, store) = try Self.disjointWorkspaces(scratch)
      let brief = try Self.run(["brief", "--json"], scratch, frontend)
      try #require(brief.termination == .exit(0), "\(brief.stdout)\(brief.stderr)")
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      let code = try Self.run(["code", "grep", "backend", "--", "needle"], scratch, frontend)
      #expect(code.termination == .exit(0), "\(code.stdout)\(code.stderr)")
      #expect(code.stdout.contains("Acme needle"))
      #expect(!code.stdout.contains("Beta needle"))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      let added = try Self.run(
        ["task", "add", "Follow Acme brief", "--start"], scratch, frontend)
      #expect(added.termination == .exit(0))
      #expect(added.stdout.contains("AC-2"))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      let betaCount = try store.read {
        try Int.fetchOne(
          $0,
          sql:
            """
            SELECT count(*) FROM task JOIN workspace ON workspace.id=task.workspace_id
            WHERE workspace.slug='beta'
            """
        )
      }
      #expect(betaCount == 1)
      let explicit = try Self.run(
        ["--ws", "beta", "code", "grep", "backend", "--", "needle"], scratch, frontend)
      #expect(explicit.termination == .exit(0))
      #expect(explicit.stdout.contains("Beta needle"))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "beta")
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='current_workspace'")
        } == "beta")
      try store.write {
        try $0.database.execute(sql: "UPDATE meta SET value='stale' WHERE key='current_workspace'")
      }
      let stale = try Self.run(["task", "show", "AC-1"], scratch, frontend)
      #expect(stale.termination == .exit(0))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
    }
  }

  @Test func currentWorkspaceIsCapturedOutsideRegisteredRepositories() throws {
    try withScratchDirectory { scratch in
      let (_, _) = try Self.disjointWorkspaces(scratch)
      let unregistered = scratch.appending(path: "unregistered")
      _ = try Self.git(["init", "-q"], scratch: scratch, cwd: unregistered)
      for cwd in [scratch.appending(path: "work"), unregistered] {
        let shown = try Self.run(["task", "show", "BE-1"], scratch, cwd)
        #expect(shown.termination == .exit(0), "\(shown.stdout)\(shown.stderr)")
        #expect(shown.stdout.contains("beta request"))
        #expect(try Self.lastLog(scratch)["workspace"] as? String == "beta")
        let code = try Self.run(["code", "grep", "backend", "--", "needle"], scratch, cwd)
        #expect(code.termination == .exit(0))
        #expect(code.stdout.contains("Beta needle"))
        #expect(try Self.lastLog(scratch)["workspace"] as? String == "beta")
      }
    }
  }

  @Test func worktreeCreatedAfterScanNeedsNoRegistration() throws {
    try withScratchDirectory { scratch in
      let (frontend, store) = try Self.disjointWorkspaces(scratch)
      let tree = scratch.appending(path: "unseen-worktree")
      _ = try Self.git(
        ["worktree", "add", "-q", "-b", "unseen", tree.path], scratch: scratch, cwd: frontend)
      let paths = try store.read { try String.fetchAll($0, sql: "SELECT path FROM repo_path") }
      try #require(paths.count == 3)
      try #require(!paths.contains { $0.lowercased() == tree.path.lowercased() })
      let shown = try Self.run(["task", "show", "AC-1"], scratch, tree)
      let loggedWorkspace = try Self.lastLog(scratch)["workspace"] as? String
      #expect(shown.termination == .exit(0), "\(shown.stdout)\(shown.stderr)")
      #expect(shown.stdout.contains("acme request"))
      #expect(loggedWorkspace == "acme")
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT path FROM repo_path") } == paths)
    }
  }

  static func refusedLocation(_ scratch: URL, broken: Bool) throws -> (URL, DatabaseStore) {
    let (repo, store) = try Self.disjointWorkspaces(scratch)
    if broken {
      try "broken\n".write(
        to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
    } else {
      let tree = scratch.appending(path: "ambiguous-tree")
      _ = try Self.git(
        ["worktree", "add", "-q", "-b", "ambiguous", tree.path], scratch: scratch, cwd: repo)
      try store.write {
        try $0.database.execute(
          sql:
            """
            INSERT INTO repo(uid,workspace_id,slug)
            SELECT 'shared',id,'shared' FROM workspace WHERE slug='beta'
            """
        )
        try $0.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo WHERE uid='shared'",
          arguments: [tree.path])
      }
    }
    return (repo, store)
  }

  @Test(arguments: [false, true])
  func locationRefusalCannotWriteThroughCurrentWorkspace(broken: Bool) throws {
    try withScratchDirectory { scratch in
      let (repo, store) = try Self.refusedLocation(scratch, broken: broken)
      let config = scratch.appending(path: "workspace.yaml")
      let yaml = try Self.run(["--ws", "beta", "ws", "show"], scratch)
      try #require(yaml.termination == .exit(0))
      try yaml.stdout.write(to: config, atomically: true, encoding: .utf8)
      for args in [
        ["task", "add", "Must refuse", "--start"], ["ws", "show"],
        ["ws", "edit", "--approved", "Edit Acme workspace"],
        ["ws", "edit", "-F", config.path, "--approved", "Edit Acme workspace"],
      ] {
        let result = try Self.run(args + ["--json"], scratch, repo)
        #expect(result.termination == .exit(broken ? 9 : 4), "\(result.stdout)\(result.stderr)")
        #expect(try Self.lastLog(scratch)["workspace"] == nil)
      }
      let count = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") }
      #expect(count == 2)
      let missingFile = try Self.run(
        ["ws", "edit", "-F", "missing", "--approved", "Edit workspace", "--json"], scratch, repo)
      #expect(missingFile.termination == .exit(9))
      #expect(missingFile.stdout.contains("UTF-8 workspace YAML"))
      #expect(try Self.lastLog(scratch)["workspace"] == nil)
      for (args, exit) in [
        (["task", "add", "Acme", "--allow-secret"], 3),
        (["task", "add", "Acme", "-F", "missing"], 1),
      ] {
        let result = try Self.run(args + ["--json"], scratch, repo)
        #expect(result.termination == .exit(Int32(exit)))
        #expect(try Self.lastLog(scratch)["workspace"] == nil)
        #expect(!result.stdout.contains("silta --ws 'beta'"))
      }
    }
  }
}
