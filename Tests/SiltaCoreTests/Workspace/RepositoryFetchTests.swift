import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RepositoryFetchTests {
  @Test(arguments: [GitTermination.exit(128), .timedOut, .signal(9)])
  func failuresKeepTimestampAndNameRetryTarget(termination: GitTermination) async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + "repos: [{slug: platform}]", to: store)
      try WorkspaceSelection.use("acme", in: store)
      let noPaths = ScriptedGitRunner(script: [])
      await #expect(throws: RepoError.localPath) {
        try await RepositoryFetch.fetch(
          nil, workspace: nil, store: store, git: noPaths,
          at: WorkspaceConfigTests.instant)
      }
      #expect(noPaths.requests.isEmpty)
      try store.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path,fetched_at) SELECT id,?,'kept' FROM repo",
          arguments: [home.path])
      }
      let git = ScriptedGitRunner(script: [
        (
          .init(arguments: ["fetch"], directory: home, timeout: 60),
          .success(.init(termination: termination, stderr: Data("private diagnostic".utf8)))
        )
      ])
      do {
        _ = try await RepositoryFetch.fetch(
          "platform", workspace: nil, store: store, git: git,
          at: WorkspaceConfigTests.instant)
        Issue.record("failed git accepted")
      } catch let error as RepoError {
        #expect(error.code == .env)
        #expect(error.message.contains("platform"))
        #expect(!error.message.contains("private diagnostic"))
        #expect(error.next == ["silta --ws 'acme' repo fetch 'platform'"])
      }
      #expect(git.isExhausted)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT fetched_at FROM repo_path") }
          == "kept")
    }
  }

  @Test func preflightAndPartialFailureHaveExplicitBoundaries() async throws {
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home.appending(path: "db"))
      try WorkspaceConfigTests.apply(
        WorkspaceConfigTests.minimal + "repos: [{slug: a}, {slug: b}, {slug: c}]", to: store)
      try WorkspaceSelection.use("acme", in: store)
      try store.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO repo_path(repo_id,path,fetched_at) SELECT id,?||slug,'kept' FROM repo",
          arguments: [home.path + "/"])
      }
      let none = ScriptedGitRunner(script: [])
      await #expect(throws: RepoError.self) {
        try await RepositoryFetch.fetch(
          nil, workspace: nil, store: store, git: none, at: WorkspaceConfigTests.instant)
      }
      #expect(none.requests.isEmpty)
      for slug in ["a", "b", "c"] {
        try FileManager.default.createDirectory(
          at: home.appending(path: slug), withIntermediateDirectories: true)
      }
      let git = ScriptedGitRunner(script: [
        (
          .init(
            arguments: ["fetch"],
            directory: URL(filePath: home.appending(path: "a").path, directoryHint: .isDirectory),
            timeout: 60),
          .success(.init(termination: .exit(0)))
        ),
        (
          .init(
            arguments: ["fetch"],
            directory: URL(filePath: home.appending(path: "b").path, directoryHint: .isDirectory),
            timeout: 60),
          .success(.init(termination: .exit(128)))
        ),
      ])
      await #expect(throws: RepoError.self) {
        try await RepositoryFetch.fetch(
          nil, workspace: nil, store: store, git: git, at: WorkspaceConfigTests.instant)
      }
      #expect(git.isExhausted)
      #expect(
        try store.read { try String.fetchAll($0, sql: "SELECT kind FROM change_log ORDER BY seq") }
          == ["workspace", "repo"])
      let times = try store.read {
        try String.fetchAll($0, sql: "SELECT fetched_at FROM repo_path ORDER BY path")
      }
      #expect(times == ["2023-11-14T22:13:20.000Z", "kept", "kept"])
    }
  }
  @Test func errorsHaveGoldenRecoveryAndEmptyWorkspaceHasNoFetches() async throws {
    let examples: [RepoError] = [
      .scan, .notFound, .localPath, .configuration(workspace: "acme"),
      .fetch(repo: "platform", workspace: "acme"),
    ]
    let rendered = examples.map {
      OutputRouter.render(.failure($0), mode: .init(json: false)).stderr
    }.joined()
    Golden.forTests().check(rendered, "repo-errors.txt")
    try await withScratchDirectory { home in
      let store = WorkspaceConfigTests.store(home)
      try WorkspaceConfigTests.apply(WorkspaceConfigTests.minimal, to: store)
      try WorkspaceSelection.use("acme", in: store)
      let git = ScriptedGitRunner(script: [])
      await #expect(throws: RepoError.notFound) {
        try await RepositoryFetch.fetch(
          nil, workspace: nil, store: store, git: git,
          at: WorkspaceConfigTests.instant)
      }
      #expect(git.requests.isEmpty)
    }
  }

}
