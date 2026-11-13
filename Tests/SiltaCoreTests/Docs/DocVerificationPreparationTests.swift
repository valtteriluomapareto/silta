import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocVerificationPreparationTests {
  static let apiSHA = String(repeating: "a", count: 40)
  static let mobileSHA = String(repeating: "b", count: 40)

  static func setup(_ home: URL) throws -> (DatabaseStore, URL) {
    let fixtures = home.appending(path: "fixtures")
    try #require(try AcmeFixtures.make(at: fixtures).termination == .exit(0))
    let repo = fixtures.appending(path: "acme-platform")
    let store = try DocsMigrationTests.copyFixture(to: home)
    try store.initialize()
    try store.write {
      try $0.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) VALUES(1,?)", arguments: [repo.path])
    }
    return (store, repo)
  }

  static func draft(_ about: [String]) -> DocDraft {
    var draft = DocDraft(slug: "rules", body: "Use the fallback.")
    draft.title = "Rules"
    draft.about = about
    return draft
  }

  static func environment(_ home: URL, store: DatabaseStore, git: any GitRunner) throws
    -> SiltaEnvironment
  {
    SiltaEnvironment(
      clock: FakeClock(now: AcmeDocAttachments.instant), ids: SeededIDGenerator(seed: 71),
      git: git,
      home: try SiltaHome.resolve(
        environment: ["SILTA_HOME": home.path], userHome: home.appending(path: "human")),
      db: store, log: FakeLog(), actor: DocStoreTests.actor)
  }

  static func request(_ ref: String, repo: URL) -> GitRequest {
    GitRequest(
      arguments: [
        "--no-pager", "-c", "format.pretty=medium", "rev-parse", "--verify", "--quiet",
        "--end-of-options", ref + "^{commit}",
      ], directory: repo)
  }

  static func result(_ sha: String) -> Result<GitResult, any Error> {
    .success(GitResult(termination: .exit(0), stdout: Data((sha + "\n").utf8)))
  }

  static func truth(_ store: DatabaseStore) throws -> [[String]] {
    try store.read { db in
      let tables = try String.fetchAll(
        db,
        sql:
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
      )
      return try tables.map { table in
        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
      }
    }
  }

  @Test func edgeUsesBothConfiguredRefsAndDeduplicatesAppsWithoutWriting() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try Self.setup(home)
      let before = try Self.truth(store)
      let git = ScriptedGitRunner(script: [
        (Self.request("origin/api", repo: repo), Self.result(Self.apiSHA)),
        (Self.request("origin/mobile", repo: repo), Self.result(Self.mobileSHA)),
      ])
      let prepared = try await DocVerification.prepare(
        Self.draft([
          "edge:mobile/api/http-api", "app:mobile", "edge:mobile/api/http-api",
        ]), workspace: 1, environment: Self.environment(home, store: store, git: git))
      #expect(
        prepared.snapshots == [
          .init(app: "api", ref: "origin/api", sha: Self.apiSHA),
          .init(app: "mobile", ref: "origin/mobile", sha: Self.mobileSHA),
        ])
      #expect(git.isExhausted && git.requests.count == 2)
      #expect(try Self.truth(store) == before)
    }
  }

  @Test(arguments: ["service:push", "topic:messaging", "edge:api/service:push/sdk"])
  func nonAppTargetsUseOnlyTheirActualApps(about: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try Self.setup(home)
      let edge = about.hasPrefix("edge:")
      let git = ScriptedGitRunner(
        script: edge ? [(Self.request("origin/api", repo: repo), Self.result(Self.apiSHA))] : [])
      let before = try Self.truth(store)
      let prepared = try await DocVerification.prepare(
        Self.draft([about]), workspace: 1,
        environment: Self.environment(home, store: store, git: git))
      #expect(
        prepared.snapshots == (edge ? [.init(app: "api", ref: "origin/api", sha: Self.apiSHA)] : [])
      )
      #expect(git.requests.count == (edge ? 1 : 0) && git.isExhausted)
      #expect(try Self.truth(store) == before)
    }
  }

  @Test func capturedSelectionSurvivesTwoAppABAAndGitRunsOutsideWrite() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try Self.setup(home)
      let git = ScriptedGitRunner(
        script: [
          (Self.request("origin/api", repo: repo), Self.result(Self.apiSHA)),
          (Self.request("origin/mobile", repo: repo), Self.result(Self.mobileSHA)),
        ],
        beforeRequest: { request in
          let ref =
            request.arguments.contains("origin/api^{commit}") ? "origin/changed" : "origin/mobile"
          try store.write {
            try $0.database.execute(
              sql: "UPDATE app SET ref=? WHERE slug='mobile'", arguments: [ref])
          }
        })
      let prepared = try await DocVerification.prepare(
        Self.draft(["edge:mobile/api/http-api"]), workspace: 1,
        environment: Self.environment(home, store: store, git: git))
      #expect(prepared.snapshots.map(\.ref) == ["origin/api", "origin/mobile"])
      #expect(git.isExhausted)
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT ref FROM app WHERE slug='mobile'") }
          == "origin/mobile")
    }
  }

  @Test func gitFailureAndMissingLocalPathLeaveAllTruthUnchanged() async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try Self.setup(home)
      let git = ScriptedGitRunner(script: [
        (Self.request("origin/api", repo: repo), .failure(SeamError.gitUnavailable))
      ])
      let before = try Self.truth(store)
      await #expect(throws: CodeError.self) {
        try await DocVerification.prepare(
          Self.draft(["app:api"]), workspace: 1,
          environment: Self.environment(home, store: store, git: git))
      }
      #expect(try Self.truth(store) == before)
      try store.write { try $0.database.execute(sql: "DELETE FROM repo_path") }
      let absent = try Self.truth(store)
      let idle = ScriptedGitRunner(script: [])
      await #expect(throws: RepoError.localPath(repo: "platform", workspace: "acme")) {
        try await DocVerification.prepare(
          Self.draft(["app:api"]), workspace: 1,
          environment: Self.environment(home, store: store, git: idle))
      }
      #expect(idle.requests.isEmpty)
      #expect(try Self.truth(store) == absent)
    }
  }
}
