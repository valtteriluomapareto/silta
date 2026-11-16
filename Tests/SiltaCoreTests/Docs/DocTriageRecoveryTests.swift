import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageRecoveryTests {
  @Test(arguments: [
    "implicit", "explicit", "prepared", "unsafe-scope", "initial-uid",
    "raced-uid", "busy-implicit", "busy-explicit", "unicode-implicit", "unicode-explicit",
  ])
  func selectionAndDiagnosticsSurvivePreparationAndRetry(mode: String) async throws {
    try await withScratchDirectory { home in
      let (seed, repo) = try Self.setup(home)
      let expected = Mutex<[[String]]?>(nil)
      let runner = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        ],
        beforeRequest: { _ in
          if ["implicit", "explicit", "prepared", "raced-uid"].contains(mode)
            || mode.hasPrefix("unicode-")
          {
            try Self.mutate(mode, seed)
            let truth = try DocVerificationPreparationTests.truth(seed)
            expected.withLock { $0 = truth }
          }
        })
      var env = try DocTriageServiceTests.environment(home, seed, git: runner)
      let ref = try DocTriageServiceTests.propose(env, about: "edge:api/service:push/sdk")
      let scope = try Self.prepare(mode, seed)
      if mode == "prepared" { env.workspaceSelection = .success("acme") }
      if mode.hasPrefix("busy-") {
        env = Self.retry(env, store: seed) {
          do {
            try Self.mutate("implicit", seed)
            let truth = try DocVerificationPreparationTests.truth(seed)
            expected.withLock { $0 = truth }
          } catch { Issue.record(error) }
        }
      }
      let before = try DocVerificationPreparationTests.truth(seed)
      let explicit = [
        "explicit", "unsafe-scope", "initial-uid", "raced-uid", "busy-explicit", "unicode-explicit",
      ]
      .contains(mode)
      var failure: (any CodedError)?
      do {
        _ = try await DocTriageService(
          environment: env, workspace: explicit ? scope : nil,
          approved: "Review Acme rules"
        ).triage(DocTriage(accept: [ref], reject: []))
      } catch let error as any CodedError { failure = error }
      try Self.check(mode, failure, seed, expected.withLock { $0 } ?? before, ref)
    }
  }

  private static func prepare(_ mode: String, _ seed: DatabaseStore) throws -> String {
    let scope =
      mode.hasPrefix("unicode-")
      ? "café" : mode == "unsafe-scope" ? String(repeating: "a", count: 52) : "acme"
    if mode.hasPrefix("unicode-") {
      try seed.write {
        try $0.database.execute(
          sql: """
            UPDATE workspace SET slug=? WHERE slug='acme';
            UPDATE workspace SET slug=? WHERE slug='beta';
            UPDATE meta SET value=? WHERE key='current_workspace'
            """,
          arguments: [scope, "cafe\u{301}", scope])
      }
    }
    if ["initial-uid", "unsafe-scope"].contains(mode) { try mutate(mode, seed) }
    return scope
  }

  private static func retry(
    _ env: SiltaEnvironment, store seed: DatabaseStore,
    changing selection: @escaping @Sendable () -> Void
  ) -> SiltaEnvironment {
    let store = DatabaseStore(
      home: URL(filePath: seed.path).deletingLastPathComponent(), clock: env.clock,
      jitter: {
        selection()
        return 0
      })
    return SiltaEnvironment(
      clock: env.clock, ids: BusyOnceProposalIDs(), git: env.git,
      home: env.home, db: store, log: env.log, actor: env.actor)
  }

  private static func setup(_ home: URL) throws -> (DatabaseStore, URL) {
    let (seed, repo) = try DocVerificationPreparationTests.setup(home)
    try seed.write {
      try $0.database.execute(
        sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
          INSERT INTO meta(key,value) VALUES('current_workspace','acme')
          ON CONFLICT(key) DO UPDATE SET value='acme';
          """)
    }
    return (seed, repo)
  }

  private static func mutate(_ mode: String, _ store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: mode.contains("uid")
          ? "UPDATE workspace SET uid=CAST(x'410042' AS TEXT) WHERE slug='acme'"
          : mode == "unsafe-scope"
            ? "UPDATE workspace SET slug='" + String(repeating: "a", count: 52)
              + "' WHERE slug='acme'"
            : mode.hasPrefix("unicode-")
              ? "UPDATE meta SET value='cafe\u{301}' WHERE key='current_workspace'"
              : "UPDATE meta SET value='beta' WHERE key='current_workspace'")
    }
  }

  private static func check(
    _ mode: String, _ failure: (any CodedError)?,
    _ store: DatabaseStore, _ before: [[String]], _ ref: String
  ) throws {
    if mode.contains("uid") {
      #expect(failure?.code == .env)
      #expect(failure?.next == ["silta backup"] && failure?.nextBy == .human)
    } else if ["implicit", "busy-implicit", "unicode-implicit"].contains(mode) {
      #expect(failure?.code == .conflict)
    } else {
      #expect(failure == nil)
      let command = try store.read {
        try String.fetchOne($0, sql: "SELECT command FROM approval ORDER BY id DESC LIMIT 1")
      }
      #expect(
        command?.contains("doc triage --accept ") == true
          && command?.contains(ref) == true)
      return
    }
    #expect(try DocVerificationPreparationTests.truth(store) == before)
  }
}
