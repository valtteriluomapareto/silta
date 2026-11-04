import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocationDistanceTests {
  @Test(arguments: [
    ([("api", 0), ("portal", 0)], nil),
    ([("api", 2), ("portal", 4)], nil),
    ([("api", 1), ("portal", 3)], "api"),
    ([("api", 7)], "api"),
    ([], nil),
  ])
  func strictConfidenceThreshold(example: ([(String, Int)], String?)) {
    let result = LocationDistance.choose(example.0)
    #expect(result.app == example.1)
    #expect(result.confidence == (example.1 == nil ? "low" : "high"))
  }

  @Test func actualCacheHitSkipsDistanceAndShallowResultsAreNotCached() async throws {
    try await withScratchDirectory { home in
      let (repo, store) = try setup(home)
      let common = commonSteps(repo)
      let distance = distanceSteps(repo)
      for (shallow, count) in [(true, 0), (false, 4), (false, 0)] {
        let script =
          common + [
            step(
              ["rev-parse", "--is-shallow-repository"],
              shallow ? "true" : "false", repo)
          ] + (count == 0 ? [] : distance)
        let runner = ScriptedGitRunner(script: script)
        let environment = try environment(runner, home: home, store: store)
        let result = try await LocationService(environment: environment).resolve(path: repo)
        #expect(result.reason == (shallow ? "shallow" : "distance"))
        #expect(result.app == nil)
        #expect(
          result.retryCandidates.map(\.app) == (shallow ? ["api", "portal"] : ["portal", "api"]))
        #expect(runner.isExhausted)
        #expect(runner.requests.filter { $0.arguments.contains("rev-list") }.count == count)
      }
    }
  }

  @Test func changingConfigurationRefusesOverrideWithoutApprovalOrDecisionRows() async throws {
    try await withScratchDirectory { home in
      let (repo, store) = try setup(home)
      let common = commonSteps(repo)
      let runner = ScriptedGitRunner(
        script: common,
        beforeRequest: { request in
          if request.arguments.last == "origin/portal^{commit}" {
            try store.write {
              try $0.database.execute(sql: "UPDATE app SET ref='origin/changed' WHERE slug='api'")
            }
          }
        })
      let service = LocationService(environment: try environment(runner, home: home, store: store))
      do {
        _ = try await service.override(path: repo, app: "api", approved: "Yes, set api")
        Issue.record("changed configuration accepted")
      } catch let error as LocationError {
        #expect(error.code == .conflict)
      }
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM worktree_override") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
      }
    }
  }

  @Test func mutationThatRacesIntoNoOpNeedsNoApprovalOrChangeRow() async throws {
    try await withScratchDirectory { home in
      let (repo, store) = try setup(home)
      let runner = ScriptedGitRunner(
        script: commonSteps(repo),
        beforeRequest: { request in
          if request.arguments.contains("--verify"), request.arguments.last == "HEAD" {
            try store.write { tx in
              try tx.database.execute(
                sql: """
                  INSERT INTO worktree_override(path,app_id,set_by)
                  SELECT ?,id,'human:acme' FROM app WHERE slug='api'
                  """, arguments: [repo.path])
              try tx.recordChange(kind: "worktree_override", rowID: 1)
            }
          }
        })
      let service = LocationService(
        environment: try environment(runner, home: home, store: store))
      let result = try await service.override(path: repo, app: "api")
      #expect(!result.approvalUsed)
      #expect(result.result.app == "api")
      try store.read { (db: Database) throws in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM worktree_override") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log") == 2)
      }
    }
  }

  private func setup(_ home: URL) throws -> (URL, DatabaseStore) {
    let original = home.appending(path: "repo")
    try FileManager.default.createDirectory(
      at: original.appending(path: ".git"), withIntermediateDirectories: true)
    let repo = try LocationPath.canonical(original)
    let store = WorkspaceConfigTests.store(home.appending(path: "db"))
    try WorkspaceConfigTests.apply(
      WorkspaceConfigTests.minimal + """
        repos: [{slug: platform}]
        apps:
          - {slug: api, repo: platform, ref: origin/api}
          - {slug: portal, repo: platform, ref: origin/portal}
        """, to: store)
    try store.write {
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo",
        arguments: [repo.path])
    }
    return (repo, store)
  }

  private func environment(_ runner: any GitRunner, home: URL, store: DatabaseStore) throws
    -> SiltaEnvironment
  {
    SiltaEnvironment(
      clock: FakeClock(now: WorkspaceConfigTests.instant), ids: SeededIDGenerator(seed: 2),
      git: runner,
      home: try SiltaHome.resolve(environment: ["SILTA_HOME": home.appending(path: "db").path]),
      db: store, log: FakeLog(), actor: .agent(tool: "codex", session: "acme"))
  }

  private func commonSteps(_ repo: URL) -> [(GitRequest, Result<GitResult, any Error>)] {
    [
      step(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        repo.appending(path: ".git").path, repo),
      step(["rev-parse", "--show-toplevel"], repo.path, repo),
      step(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"],
        repo.appending(path: ".git").path, repo),
      step(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", "origin/api^{commit}"], "aaaaaaaa",
        repo),
      step(
        ["rev-parse", "--verify", "--quiet", "--end-of-options", "origin/portal^{commit}"],
        "bbbbbbbb", repo),
      step(["symbolic-ref", "--quiet", "--short", "HEAD"], "", repo, status: 1),
      step(["rev-parse", "--verify", "HEAD"], "aaaaaaaa", repo),
    ]
  }

  private func distanceSteps(_ repo: URL) -> [(GitRequest, Result<GitResult, any Error>)] {
    [
      step(["rev-list", "--count", "aaaaaaaa..aaaaaaaa"], "2", repo),
      step(["rev-list", "--count", "aaaaaaaa..aaaaaaaa"], "0", repo),
      step(["rev-list", "--count", "bbbbbbbb..aaaaaaaa"], "1", repo),
      step(["rev-list", "--count", "aaaaaaaa..bbbbbbbb"], "0", repo),
    ]
  }

  private func step(_ arguments: [String], _ output: String, _ directory: URL, status: Int32 = 0)
    -> (GitRequest, Result<GitResult, any Error>)
  {
    (
      .init(arguments: arguments, directory: directory),
      .success(.init(termination: .exit(status), stdout: Data((output + "\n").utf8)))
    )
  }
}
