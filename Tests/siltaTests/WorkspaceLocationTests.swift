import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct WorkspaceLocationTests {
  static let environment = TaskCommandTests.fixed

  static func run(_ args: [String], _ scratch: URL, _ cwd: URL? = nil) throws -> CLIResult {
    try SiltaBinary.run(args, in: scratch, cwd: cwd, environment: environment)
  }

  static func setup(_ scratch: URL) throws -> (URL, DatabaseStore) {
    let fixtures = scratch.appending(path: "fixtures")
    try #require(try AcmeFixtures.make(at: fixtures).termination == .exit(0))
    try #require(
      try run(["init", "--scan", fixtures.path, "--slug", "acme", "--prefix", "AC"], scratch)
        .termination == .exit(0))
    try #require(
      try run(["--ws", "acme", "task", "add", "Acme request", "--start"], scratch)
        .termination == .exit(0))
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    return (fixtures.appending(path: "acme-platform"), store)
  }

  static func secondWorkspace(_ scratch: URL) throws {
    let tree = scratch.appending(path: "beta-repo")
    try #require(
      try SiltaBinary.runProcess(
        URL(filePath: "/usr/bin/git"),
        ["worktree", "add", "-q", "-b", "beta", tree.path], in: scratch,
        cwd: scratch.appending(path: "fixtures/acme-platform")
      ).termination == .exit(0))
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
          INSERT INTO repo(uid,workspace_id,slug)
            SELECT 'beta-repo',id,'beta-repo' FROM workspace WHERE slug='beta';
          """)
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo WHERE uid='beta-repo'",
        arguments: [tree.path])
    }
    try #require(
      try run(["--ws", "beta", "task", "add", "Beta request", "--start"], scratch)
        .termination == .exit(0))
  }

  @Test func freshScanSupportsTaskAndCodeWithoutWorkspaceUse() throws {
    try withScratchDirectory { scratch in
      let (repo, store) = try Self.setup(scratch)
      let task = try Self.run(["task", "show", "AC-1", "--json"], scratch, repo)
      #expect(task.termination == .exit(0), "\(task.stdout)\(task.stderr)")
      #expect(task.stdout.contains("Acme request"))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      let code = try Self.run(
        ["code", "grep", "acme-platform-api", "--json", "--", "Acme"], scratch, repo)
      #expect(code.termination == .exit(0), "\(code.stdout)\(code.stderr)")
      #expect(code.stdout.contains("README.md"))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      let printed = try Self.run(["task", "edit", "AC-1", "--print"], scratch, repo)
      #expect(printed.termination == .exit(0))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='current_workspace'")
        } == nil)
    }
  }

  @Test func commonDirectoryIdentityIgnoresAppAmbiguity() throws {
    try withScratchDirectory { scratch in
      let (repo, store) = try Self.setup(scratch)
      let nested = repo.appending(path: "nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let alias = scratch.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
      let broken = scratch.appending(path: "broken-clone/.git")
      try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
      try "broken\n".write(to: broken.appending(path: "HEAD"), atomically: true, encoding: .utf8)
      try store.write {
        try $0.database.execute(sql: "DELETE FROM repo_path WHERE path LIKE '%portal-worktree'")
        for (slug, path) in [
          ("duplicate", scratch.appending(path: "fixtures/acme-portal-worktree").path),
          ("missing", scratch.appending(path: "missing-clone").path),
          ("broken", scratch.appending(path: "broken-clone").path),
        ] {
          try $0.database.execute(
            sql: """
              INSERT INTO repo(uid,workspace_id,slug)
              SELECT ?,id,? FROM workspace WHERE slug='acme'
              """,
            arguments: [slug, slug])
          try $0.database.execute(
            sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo WHERE uid=?",
            arguments: [path, slug])
        }
      }
      try store.write {
        try $0.database.execute(sql: "UPDATE app SET ref='missing-' || slug, prod_ref=NULL")
      }
      let location = try Self.run(["where", "--json"], scratch, repo)
      try #require(location.termination == .exit(0), "\(location.stdout)\(location.stderr)")
      #expect(location.stdout.contains("\"confidence\":\"low\""))
      for cwd in [nested, alias, scratch.appending(path: "fixtures/acme-portal-worktree")] {
        let result = try Self.run(["ws", "show", "--json"], scratch, cwd)
        #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        #expect(result.stdout.contains("\"workspace\":\"acme\""))
      }
    }
  }

  @Test func explicitAndCurrentSelectionWinAndInvalidSelectionsRefuse() throws {
    try withScratchDirectory { scratch in
      let (repo, store) = try Self.setup(scratch)
      try Self.secondWorkspace(scratch)
      try #require(try Self.run(["ws", "use", "beta"], scratch).termination == .exit(0))
      let current = try Self.run(["task", "show", "BE-1"], scratch, repo)
      #expect(current.termination == .exit(0))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "beta")
      #expect(
        try Self.run(["--ws", "acme", "task", "show", "AC-1"], scratch, repo)
          .termination == .exit(0))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      let argument = try Self.run(["--ws", "beta", "ws", "show", "acme", "--json"], scratch, repo)
      #expect(argument.stdout.contains("\"workspace\":\"acme\""))
      let unknown = try Self.run(["--ws", "absent", "task", "show", "AC-1"], scratch, repo)
      #expect(unknown.termination == .exit(2))
      #expect(unknown.stderr.contains("No workspace is named"))
      #expect(try Self.lastLog(scratch)["workspace"] == nil)
      try store.write {
        try $0.database.execute(sql: "UPDATE meta SET value='stale' WHERE key='current_workspace'")
      }
      let stale = try Self.run(["task", "show", "AC-1"], scratch, repo)
      #expect(stale.termination == .exit(2))
      #expect(stale.stderr.contains("No matching workspace is selected"))
      #expect(try Self.lastLog(scratch)["workspace"] == nil)
    }
  }

  @Test func locationLedCommandsKeepTheirOwnPrecedence() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      try Self.secondWorkspace(scratch)
      try #require(try Self.run(["ws", "use", "beta"], scratch).termination == .exit(0))
      for command in ["where", "brief", "status"] {
        let result = try Self.run([command, "--json"], scratch, repo)
        #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
        #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      }
    }
  }

  @Test func multipleWorkspacesRefuseWithScopedDiscovery() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      try Self.secondWorkspace(scratch)
      for args in [["task", "show", "AC-1"], ["ws", "edit", "--approved", "Edit Acme workspace"]] {
        for json in [false, true] {
          let result = try Self.run(args + (json ? ["--json"] : []), scratch, repo)
          #expect(result.termination == .exit(4))
          Golden.forTests().check(
            json ? result.stdout : result.stderr,
            "workspace-location-ambiguous" + (json ? ".json" : ".txt"))
          #expect(try Self.lastLog(scratch)["workspace"] == nil)
        }
      }
      for workspace in ["acme", "beta"] {
        #expect(
          try Self.run(["--ws", workspace, "ws", "show"], scratch, repo)
            .termination == .exit(0))
      }
    }
  }

  @Test func inferredWritesConsumeStdinOnceAndDoNotPersistSelection() throws {
    try withScratchDirectory { scratch in
      let (repo, store) = try Self.setup(scratch)
      let body = scratch.appending(path: "body.md")
      try "Acme input body".write(to: body, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c", "input=$1; shift; exec \"$@\" < \"$input\"", "stdin", body.path,
          try SiltaBinary.url().path, "task", "add", "Acme second", "--start", "-F", "-",
        ],
        in: scratch, cwd: repo, environment: Self.environment)
      #expect(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      let shown = try Self.run(["task", "show", "AC-2"], scratch, repo)
      #expect(shown.stdout.contains("Acme input body"))
      let taskCount = try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") }
      #expect(taskCount == 2)
      #expect(
        try store.read {
          try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key='current_workspace'")
        } == nil)
      #expect(try Self.run(["task", "show", "AC-1"], scratch).termination == .exit(2))
    }
  }

  @Test func operationFailuresKeepInferredScopeAndEarlierRefusalsWin() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      let missing = try Self.run(["task", "show", "AC-99", "--json"], scratch, repo)
      #expect(missing.termination == .exit(2))
      #expect(missing.stdout.contains("silta --ws 'acme' task ls"))
      #expect(try Self.lastLog(scratch)["workspace"] as? String == "acme")
      try Self.secondWorkspace(scratch)
      for broken in [false, true] {
        if broken {
          try "broken\n".write(
            to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        }
        if broken {
          let result = try Self.run(["task", "show", "AC-1", "--json"], scratch, repo)
          #expect(result.termination == .exit(9))
          #expect(result.stdout.contains("Could not read git metadata"))
        }
        for args in [["task", "add", "Acme", "--allow-secret"], ["ws", "edit"]] {
          let result = try Self.run(args + ["--json"], scratch, repo)
          #expect(result.termination == .exit(3))
          #expect(result.stdout.contains("human_only"))
        }
        let input = try Self.run(["task", "add", "Acme", "-F", "missing", "--json"], scratch, repo)
        #expect(input.termination == .exit(1))
        #expect(input.stdout.contains("invalid"))
      }
    }
  }

  @Test func unregisteredPathsDoNotSelectOrInitializeStorage() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      let outside = try Self.run(["task", "show", "AC-1"], scratch)
      #expect(outside.termination == .exit(2))
      let unregistered = scratch.appending(path: "unregistered")
      try #require(
        try SiltaBinary.runProcess(
          URL(filePath: "/usr/bin/git"), ["init", "-q"], in: scratch, cwd: unregistered
        ).termination == .exit(0))
      #expect(
        try Self.run(["task", "show", "AC-1"], scratch, unregistered)
          .termination == .exit(2))
      #expect(try Self.lastLog(scratch)["workspace"] == nil)
      let empty = scratch.appending(path: "empty")
      let missing = try Self.run(["task", "show", "AC-1"], empty, repo)
      #expect(missing.termination == .exit(2))
      #expect(
        !FileManager.default.fileExists(atPath: empty.appending(path: "silta-home/silta.db").path))
      let usage = try Self.run(["task", "show", "--nope"], scratch, repo)
      #expect(usage.termination == .exit(1))
      #expect(try Self.lastLog(scratch)["workspace"] == nil)
      let guide = try Self.run(["guide"], scratch, repo)
      #expect(guide.termination == .exit(0))
      #expect(try Self.lastLog(scratch)["workspace"] == nil)
    }
  }
}

extension WorkspaceLocationTests {
  static func lastLog(_ scratch: URL) throws -> [String: Any] {
    let text = try String(
      contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
    let line = try #require(text.split(separator: "\n").last)
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  }

  @Test func invalidEditorApprovalDoesNotResolveLocation() throws {
    try withScratchDirectory { scratch in
      let (repo, _) = try Self.setup(scratch)
      for words in ["", "   ", "<the human's words>", String(repeating: "a", count: 301)] {
        let result = try Self.run(["ws", "edit", "--approved", words, "--json"], scratch, repo)
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("\"code\":\"invalid\""))
        #expect(try Self.lastLog(scratch)["workspace"] == nil)
      }
    }
  }

}
