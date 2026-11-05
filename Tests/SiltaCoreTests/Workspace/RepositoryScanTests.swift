import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RepositoryScanTests {
  static let refs = "origin/main\norigin/api\norigin/api-prod\norigin/portal\norigin/portal-prod\n"

  static func path(_ url: URL) throws -> URL {
    let values = try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values.volumeSupportsCaseSensitiveNames == false
      ? URL(filePath: url.path.lowercased()) : url
  }

  static func script(
    _ candidate: URL, main: URL? = nil, refs: String = refs,
    remote: GitResult = .init(
      termination: .exit(0), stdout: Data("git@example.com:acme/platform.git\n".utf8))
  )
    -> [(GitRequest, Result<GitResult, any Error>)]
  {
    let main = main ?? candidate
    let refsRequest = GitRequest(
      arguments: ["for-each-ref", "--format=%(refname:short)", "refs/remotes"], directory: main)
    return [
      (
        .init(arguments: ["worktree", "list", "--porcelain", "-z"], directory: candidate),
        .success(
          .init(termination: .exit(0), stdout: Data("worktree \(main.path)\0HEAD acme\0\0".utf8)))
      ),
      (.init(arguments: ["remote", "get-url", "origin"], directory: main), .success(remote)),
      (
        refsRequest,
        .success(.init(termination: .exit(0), stdout: Data(refs.utf8)))
      ),
    ]
  }

  @Test(arguments: [0, 1, 2, 3]) func discoveryDepthIsBounded(depth: Int) async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "acme")
      let repo = (0..<depth).reduce(root) { path, _ in path.appending(path: "nested") }
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      if depth == 0 {
        try FileManager.default.createDirectory(
          at: repo.appending(path: "nested/.git"), withIntermediateDirectories: true)
      } else {
        try Data().write(to: root.appending(path: "readme"))
      }
      let candidate = try Self.path(repo)
      let git = ScriptedGitRunner(script: depth <= 2 ? Self.script(candidate) : [])
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let outcome = try await RepositoryScan.scan(
        [root], store: store, git: git,
        identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      #expect(outcome.workspace == "acme")
      #expect(git.isExhausted)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo") }
          == (depth <= 2 ? 1 : 0))
      if depth <= 2 {
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM app") } == 3)
        #expect(
          try store.read {
            try String.fetchAll(
              $0, sql: "SELECT prod_ref FROM app WHERE prod_ref IS NOT NULL ORDER BY prod_ref")
          } == ["origin/api-prod", "origin/portal-prod"])
      }
    }
  }

  @Test func worktreesAndRootAliasesDeduplicateAndRescanPreservesConfig() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "acme")
      let main = root.appending(path: "z-main")
      let linked = root.appending(path: "a-linked")
      for repo in [main, linked] {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data().write(to: repo.appending(path: ".git"))
      }
      let alias = home.appending(path: "alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
      let mainPath = try Self.path(main)
      let linkPath = try Self.path(linked)
      var script = Self.script(linkPath, main: mainPath)
      script += [Self.script(mainPath)[0]]
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let git = ScriptedGitRunner(script: script)
      _ = try await RepositoryScan.scan(
        [root, root, alias], store: store, git: git,
        identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      #expect(git.isExhausted)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo") } == 1)
      try store.write { tx in
        try tx.database.execute(sql: "UPDATE workspace SET name='Edited',settings='{\"future\":1}'")
        try tx.database.execute(sql: "ALTER TABLE repo_path ADD COLUMN future TEXT")
        try tx.database.execute(
          sql: "UPDATE repo_path SET fetched_at='kept',future='kept',path='/acme/missing'")
      }
      let again = ScriptedGitRunner(script: script)
      _ = try await RepositoryScan.scan(
        [root], store: store, git: again,
        identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant))
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT name FROM workspace") } == "Edited")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT fetched_at FROM repo_path") }
          == "kept")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT future FROM repo_path") } == "kept")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT path FROM repo_path") }
          == mainPath.path)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log") } == 2)
    }
  }

  @Test func mainProdPairDoesNotDuplicateDefaultAndMissingOriginIsAllowed() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "acme")
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      let git = ScriptedGitRunner(
        script: Self.script(
          try Self.path(repo),
          refs: "origin/main\norigin/main-prod\n", remote: .init(termination: .exit(2))))
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      _ = try await RepositoryScan.scan(
        [repo], store: store, git: git,
        identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      #expect(git.isExhausted)
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM app") } == 1)
      #expect(try store.read { try String.fetchOne($0, sql: "SELECT remote_url FROM repo") } == nil)
    }
  }

  @Test func pathConflictRollsBackEntireNewWorkspace() async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "new")
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      let path = try Self.path(repo)
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + "repos: [{slug: old}]", to: store)
      try store.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [path.path])
      }
      let git = ScriptedGitRunner(script: Self.script(path))
      await #expect(throws: WorkspaceError.self) {
        try await RepositoryScan.scan(
          [repo], store: store, git: git,
          identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant))
      }
      #expect(try WorkspaceSelection.list(in: store).map(\.slug) == ["acme"])
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_log") } == 1)
    }
  }
  @Test(arguments: [
    GitResult(termination: .exit(128)),
    GitResult(termination: .exit(0), stdout: Data([0xff])),
  ])
  func scanFailuresNeverCreateStorage(remote: GitResult) async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "acme")
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      let git = ScriptedGitRunner(script: Self.script(try Self.path(repo), remote: remote))
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: RepoError.self) {
        try await RepositoryScan.scan(
          [repo], store: store, git: git,
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      #expect(!FileManager.default.fileExists(atPath: store.path))
    }
  }

  @Test func duplicateSlugsAreRefusedBeforeApplying() async throws {
    try await withScratchDirectory { home in
      let root = home.appending(path: "acme")
      let repos = [root.appending(path: "a/same"), root.appending(path: "b/same")]
      var script: [(GitRequest, Result<GitResult, any Error>)] = []
      for repo in repos {
        try FileManager.default.createDirectory(
          at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        script += Self.script(try Self.path(repo))
      }
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: RepoError.duplicateSlug) {
        try await RepositoryScan.scan(
          [root], store: store, git: ScriptedGitRunner(script: script),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

  @Test func emptyRootsAndUnknownRegisteredSlugsRefuseWithoutReplacingConfig() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      let none = ScriptedGitRunner(script: [])
      await #expect(throws: RepoError.scan) {
        try await RepositoryScan.scan(
          [], store: store, git: none,
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + "repos: [{slug: old}]", to: store)
      let repo = home.appending(path: "new")
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      await #expect(throws: RepoError.configuration(repo: "new", workspace: "acme")) {
        try await RepositoryScan.scan(
          [repo], store: store,
          git: ScriptedGitRunner(script: Self.script(try Self.path(repo))),
          identity: (SeededIDGenerator(seed: 2), WorkspaceConfigTests.instant), workspace: "acme")
      }
      #expect(try store.read { try String.fetchAll($0, sql: "SELECT slug FROM repo") } == ["old"])
    }
  }

  @Test(arguments: [0, 1, 2]) func malformedWorktreeAndFailedRefQueryAreEnvironmentErrors(
    scenario: Int
  ) async throws {
    try await withScratchDirectory { home in
      let repo = home.appending(path: "acme")
      try FileManager.default.createDirectory(
        at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      let path = try Self.path(repo)
      var script = Self.script(path)
      if scenario == 0 {
        script[0].1 = .success(
          .init(termination: .exit(0), stdout: Data("invalidxx\(path.path)\0".utf8)))
      } else if scenario == 1 {
        script[2].1 = .success(.init(termination: .exit(1), stdout: Data(Self.refs.utf8)))
      } else {
        script[2].1 = .success(.init(termination: .exit(0), stdout: Data([0xff])))
      }
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: RepoError.scan) {
        try await RepositoryScan.scan(
          [repo], store: store, git: ScriptedGitRunner(script: script),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant))
      }
      #expect(!FileManager.default.fileExists(atPath: store.path))
    }
  }

  @Test func explicitWorkspaceMustAlreadyExist() async throws {
    try await withScratchDirectory { (home: URL) async throws in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      await #expect(throws: WorkspaceError.self) {
        try await RepositoryScan.scan(
          [home], store: store, git: ScriptedGitRunner(script: []),
          identity: (SeededIDGenerator(seed: 1), WorkspaceConfigTests.instant), workspace: "absent")
      }
      #expect(try WorkspaceSelection.list(in: store).isEmpty)
    }
  }

}
