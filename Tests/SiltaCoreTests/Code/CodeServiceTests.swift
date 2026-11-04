import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodeServiceTests {
  private let sha = String(repeating: "a", count: 40)

  @Test func lineRangesPreserveLineEndingsAndTruncate() throws {
    let unreadable = CodeError.git(repo: "platform", workspace: "acme")
    let show = { (lines: String, text: String) in
      try CodeRead.show("file", lines: lines).formatted(
        text, sha: sha, subpath: "", unreadable: unreadable)
    }
    #expect(try show("2-2", "one\r\ntwo\r\n").output == "two\r\n")
    #expect(try show("2", "one\ntwo").output == "two")
    let past = try show("2-20", "one\ntwo\n")
    #expect(past.output == "two\n")
    #expect(past.warnings.map(\.code) == ["lines_past_eof"])
    #expect(try show("3-20", "one\ntwo\n").output == "")
    #expect(
      try show("1-1", "").warnings.map(\.message) == [
        "\"file\" has 0 lines; --lines 1-1 goes past the end."
      ])
    for invalid in ["0", "1-", "-1", "2-1", "+1", "1-2-3", "a"] {
      #expect(throws: CodeError.self) { try show(invalid, "one\n") }
    }
  }

  @Test func errorsHaveGoldenRecoveryCommands() {
    let errors: [CodeError] = [
      .invalid("Use an app-relative path.", command: "silta code show"),
      .notFound("Git ref missing.", next: ["silta --ws 'acme' ws show"]),
      .git(repo: "platform", workspace: "acme"),
      .timeout(command: "silta code grep"),
      .fetch(repo: "platform", retry: "silta --ws 'acme' code ls 'api'"),
    ]
    for json in [false, true] {
      let rendered = errors.map { OutputRouter.render(.failure($0), mode: .init(json: json)) }
      Golden.forTests().check(
        rendered.map { json ? $0.stdout : $0.stderr }.joined(),
        json ? "code-errors.json" : "code-errors.txt")
    }
  }

  @Test(arguments: [Double(-1), 86_399, 86_400, 90_000])
  func staleBoundaryAndFetchRefresh(age: Double) async throws {
    try await withScratchDirectory { home in
      let store = try setup(home)
      if age >= 0 {
        let fetched = WorkspaceConfigTests.instant.addingTimeInterval(-age)
        try store.write {
          try $0.database.execute(
            sql: "UPDATE repo_path SET fetched_at=?",
            arguments: [
              fetched.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            ])
        }
      }
      let git = ScriptedGitRunner(script: reads(home))
      let result = try await read(store, home, git)
      #expect(git.isExhausted)
      #expect(result.output == "committed\n")
      #expect(result.warnings.count == (age < 0 || age >= 86_400 ? 1 : 0))
      if age >= 86_400 { #expect(result.warnings[0].message.contains("\(Int(age / 3600)) h ago")) }
      let fetch = ScriptedGitRunner(
        script: [
          (
            .init(arguments: ["fetch"], directory: home, timeout: 60),
            .success(.init(termination: .exit(0)))
          )
        ] + reads(home))
      let refreshed = try await read(store, home, fetch, fetch: true)
      #expect(refreshed.warnings.isEmpty)
      #expect(fetch.isExhausted)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT fetched_at FROM repo_path") }
          == "2023-11-14T22:13:20.000Z")
    }
  }

  @Test(arguments: [GitTermination.signal(9), .exit(128)])
  func gitFaultsAndFailedFetchStopWithoutWriting(termination: GitTermination) async throws {
    try await withScratchDirectory { home in
      let store = try setup(home)
      for index in reads(home).indices {
        var script = Array(reads(home).prefix(index))
        script.append(
          (
            reads(home)[index].0,
            .success(.init(termination: termination, stderr: Data("private".utf8)))
          ))
        let git = ScriptedGitRunner(script: script)
        do {
          _ = try await read(store, home, git)
          Issue.record("Git fault was accepted")
        } catch let error as CodeError { checkEnvironment(error) }
        #expect(git.isExhausted)
      }
      let fetch = ScriptedGitRunner(script: [
        (
          .init(arguments: ["fetch"], directory: home, timeout: 60),
          .success(.init(termination: termination))
        )
      ])
      let error = await #expect(throws: CodeError.self) {
        try await read(store, home, fetch, fetch: true)
      }
      #expect(error?.next == ["silta --ws 'acme' code show 'api' -- 'README.md'"])
      #expect(fetch.isExhausted)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT fetched_at FROM repo_path") } == nil)
    }
  }

  @Test func invalidInputsDoNotInvokeGitAndStaleNestedCloneIsRefused() async throws {
    try await withScratchDirectory { home in
      let store = try setup(home)
      let git = ScriptedGitRunner(script: [])
      for op in [
        CodeRead.show("../README", lines: nil), .grep("x", pathspec: ":(top)*"),
        .list("/absolute"), .log(nil, count: 0), .show("README", lines: "0-2"),
      ] {
        await #expect(throws: CodeError.self) {
          try await CodeService(
            workspace: "acme", store: store, git: git, at: WorkspaceConfigTests.instant
          ).read(op, target: "api")
        }
      }
      for target in ["@ref", "api@", "api\0"] {
        await #expect(throws: CodeError.self) {
          try await CodeService(
            workspace: "acme", store: store, git: git, at: WorkspaceConfigTests.instant
          ).read(.list(nil), target: target)
        }
      }
      try FileManager.default.removeItem(at: home.appending(path: ".git"))
      await #expect(throws: RepoError.self) { try await read(store, home, git) }
      #expect(git.requests.isEmpty)
    }
  }

  @Test func spawnFailureIsPrivateAndActionable() async throws {
    try await withScratchDirectory { home in
      let store = try setup(home)
      let spawn = ScriptedGitRunner(script: [(reads(home)[0].0, .failure(SeamError.gitUnavailable))]
      )
      do {
        _ = try await read(store, home, spawn)
        Issue.record("Spawn failure was accepted")
      } catch let error as CodeError { checkEnvironment(error) }
      #expect(spawn.isExhausted)
    }
  }

  @Test func timeoutsSuggestNarrowingTheRead() async throws {
    try await withScratchDirectory { home in
      let store = try setup(home)
      let git = ScriptedGitRunner(script: [
        (reads(home)[0].0, .success(.init(termination: .timedOut)))
      ])
      let error = await #expect(throws: CodeError.self) { try await read(store, home, git) }
      #expect(error?.message.contains("narrow") == true)
      #expect(error?.next == ["silta code show --help"])
      #expect(error?.nextBy == .agent)
    }
  }

  @Test func unreadableGrepOutputIsACodeError() {
    #expect(throws: CodeError.self) {
      try CodeRead.grep("x", pathspec: nil).formatted(
        "garbage", sha: sha, subpath: "", unreadable: .git(repo: "platform", workspace: "acme"))
    }
  }

  private func checkEnvironment(_ error: CodeError) {
    #expect(error.code == .env)
    #expect(error.exitCode == 9)
    #expect(!error.message.contains("private"))
    #expect(error.next == ["silta --ws 'acme' repo fetch 'platform'"])
  }

  private func setup(_ home: URL) throws -> DatabaseStore {
    try FileManager.default.createDirectory(
      at: home.appending(path: ".git"), withIntermediateDirectories: true)
    let store = WorkspaceConfigTests.store(home.appending(path: "db"))
    try WorkspaceConfigTests.apply(
      WorkspaceConfigTests.minimal + """
        repos: [{slug: platform}]
        apps: [{slug: api, repo: platform, ref: origin/api}]
        """, to: store)
    try store.write {
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [home.path])
    }
    return store
  }

  private func reads(_ home: URL) -> [(GitRequest, Result<GitResult, any Error>)] {
    [
      (
        .init(
          arguments: [
            "--no-pager", "-c", "format.pretty=medium", "rev-parse", "--verify", "--quiet",
            "--end-of-options",
            "origin/api^{commit}",
          ], directory: home),
        .success(.init(termination: .exit(0), stdout: Data((sha + "\n").utf8)))
      ),
      (
        .init(
          arguments: [
            "--no-pager", "-c", "format.pretty=medium", "--literal-pathspecs", "ls-tree", "-z", sha,
            "--", "README.md",
          ], directory: home),
        .success(
          .init(termination: .exit(0), stdout: Data(("100644 blob " + sha + "\tREADME.md\0").utf8)))
      ),
      (
        .init(
          arguments: [
            "--no-pager", "-c", "format.pretty=medium", "--attr-source=" + sha, "show",
            "--format=", "--no-color",
            "--no-ext-diff", "--no-textconv",
            sha + ":README.md",
          ], directory: home),
        .success(.init(termination: .exit(0), stdout: Data("committed\n".utf8)))
      ),
    ]
  }

  private func read(_ store: DatabaseStore, _ home: URL, _ git: any GitRunner, fetch: Bool = false)
    async throws -> CodeResult
  {
    try await CodeService(
      workspace: "acme", store: store, git: git, at: WorkspaceConfigTests.instant
    )
    .read(.show("README.md", lines: nil), target: "api", fetch: fetch)
  }
}
