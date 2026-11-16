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
    "raced-uid", "busy-implicit", "busy-explicit",
  ])
  func selectionAndDiagnosticsSurvivePreparationAndRetry(mode: String) async throws {
    try await withScratchDirectory { home in
      let (seed, repo) = try DocVerificationPreparationTests.setup(home)
      let expected = Mutex<[[String]]?>(nil)
      try seed.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
            INSERT INTO meta(key,value) VALUES('current_workspace','acme')
            ON CONFLICT(key) DO UPDATE SET value='acme';
            """)
      }
      let runner = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        ],
        beforeRequest: { _ in
          if ["implicit", "explicit", "prepared", "raced-uid"].contains(mode) {
            try Self.mutate(mode, seed)
            let truth = try DocVerificationPreparationTests.truth(seed)
            expected.withLock { $0 = truth }
          }
        })
      var env = try DocTriageServiceTests.environment(home, seed, git: runner)
      let ref = try DocTriageServiceTests.propose(env, about: "edge:api/service:push/sdk")
      let scope = mode == "unsafe-scope" ? String(repeating: "a", count: 52) : "acme"
      if mode == "prepared" { env.workspaceSelection = .success("acme") }
      if ["initial-uid", "unsafe-scope"].contains(mode) { try Self.mutate(mode, seed) }
      if mode.hasPrefix("busy-") {
        let retryStore = DatabaseStore(
          home: URL(filePath: seed.path).deletingLastPathComponent(),
          clock: env.clock,
          jitter: {
            do {
              try Self.mutate("implicit", seed)
              let truth = try DocVerificationPreparationTests.truth(seed)
              expected.withLock { $0 = truth }
            } catch { Issue.record(error) }
            return 0
          })
        env = SiltaEnvironment(
          clock: env.clock, ids: BusyOnceProposalIDs(), git: runner,
          home: env.home, db: retryStore, log: env.log, actor: env.actor)
      }
      let before = try DocVerificationPreparationTests.truth(seed)
      let explicit = ["explicit", "unsafe-scope", "initial-uid", "raced-uid", "busy-explicit"]
        .contains(mode)
      var failure: (any CodedError)?
      do {
        _ = try await DocTriageService(
          environment: env, workspace: explicit ? scope : nil,
          approved: "Review Acme rules"
        ).triage(DocTriage(accept: [ref], reject: []))
      } catch let error as any CodedError { failure = error }
      if ["implicit", "initial-uid", "raced-uid", "busy-implicit", "unsafe-scope"].contains(mode) {
        withKnownIssue("Triage preserves selection and diagnostic policy") {
          try Self.check(mode, failure, seed, expected.withLock { $0 } ?? before)
        }
      } else {
        try Self.check(mode, failure, seed, before)
      }
    }
  }

  private static func mutate(_ mode: String, _ store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: mode.contains("uid")
          ? "UPDATE workspace SET uid=CAST(x'410042' AS TEXT) WHERE slug='acme'"
          : mode == "unsafe-scope"
            ? "UPDATE workspace SET slug='" + String(repeating: "a", count: 52)
              + "' WHERE slug='acme'"
            : "UPDATE meta SET value='beta' WHERE key='current_workspace'")
    }
  }

  private static func check(
    _ mode: String, _ failure: (any CodedError)?,
    _ store: DatabaseStore, _ before: [[String]]
  ) throws {
    if mode.contains("uid") {
      #expect(failure?.code == .env)
      #expect(failure?.next == ["silta backup"] && failure?.nextBy == .human)
    } else if ["implicit", "busy-implicit"].contains(mode) {
      #expect(failure?.code == .conflict)
    } else {
      #expect(failure == nil)
      let command = try store.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
      #expect(
        command?.contains("doc triage --accept ") == true
          && command?.contains("doc:rules@1") == true)
      return
    }
    #expect(try DocVerificationPreparationTests.truth(store) == before)
  }
}
