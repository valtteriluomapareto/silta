import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageRejectionRetryTests {
  @Test(arguments: ["current", "explicit", "prepared", "uid"])
  func retryNeverRetargetsTheSameRefInAnotherWorkspace(mode: String) async throws {
    try await withScratchDirectory { home in
      let seed = try AcmeDocAttachments.make(in: home)
      try seed.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('beta-push',2,'push','Push');
            INSERT INTO meta(key,value) VALUES('current_workspace','acme')
            ON CONFLICT(key) DO UPDATE SET value='acme';
            """)
      }
      let base = try DocTriageServiceTests.environment(home, seed)
      let ref = try DocTriageServiceTests.propose(base, about: "service:push")
      #expect(
        try DocProposalService(environment: base, workspace: "beta").propose(
          DocProposalRequest(slug: "rules", title: "Rules", about: ["service:push"], why: "Share."),
          input: { "Beta rules." }
        ).ref == ref)
      let expected = Mutex<[[String]]?>(nil)
      let retries = Mutex(0)
      let store = DatabaseStore(
        home: URL(filePath: seed.path).deletingLastPathComponent(),
        clock: base.clock,
        jitter: {
          retries.withLock { $0 += 1 }
          do {
            try seed.write {
              try $0.database.execute(
                sql: mode == "uid"
                  ? "UPDATE workspace SET uid='replacement' WHERE slug='acme'"
                  : "UPDATE meta SET value='beta' WHERE key='current_workspace'")
            }
            let truth = try DocVerificationPreparationTests.truth(seed)
            expected.withLock { $0 = truth }
          } catch { Issue.record(error) }
          return 0
        })
      var env = SiltaEnvironment(
        clock: base.clock, ids: BusyOnceProposalIDs(), git: base.git,
        home: base.home, db: store, log: base.log, actor: base.actor)
      if mode == "prepared" { env.workspaceSelection = .success("acme") }
      var failure: (any CodedError)?
      do {
        _ = try await DocTriageService(
          environment: env,
          workspace: mode == "explicit" || mode == "uid" ? "acme" : nil, approved: "Reject rules"
        )
        .triage(DocTriage(accept: [], reject: [ref]))
      } catch let error as any CodedError { failure = error }
      #expect(retries.withLock { $0 } == 1)
      if ["current", "uid"].contains(mode) {
        #expect(failure?.code == .conflict)
        #expect(try DocVerificationPreparationTests.truth(seed) == expected.withLock { $0 })
      } else {
        #expect(failure == nil)
        #expect(
          try seed.read {
            try String.fetchAll(
              $0,
              sql:
                "SELECT r.state FROM doc_rev r JOIN doc d ON d.id=r.doc_id ORDER BY d.workspace_id")
          } == ["rejected", "proposed"])
      }
    }
  }

  @Test(arguments: ["unsafe-scope", "initial-uid", "approval", "change_log"])
  func auditDiagnosticsAndLateFailureKeepTheirContracts(mode: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try DocTriageServiceTests.environment(home, store)
      let ref = try DocTriageServiceTests.propose(env, about: "service:push")
      let scope = mode == "unsafe-scope" ? String(repeating: "a", count: 52) : "acme"
      try store.write {
        if mode == "unsafe-scope" {
          try $0.database.execute(sql: "UPDATE workspace SET slug=?", arguments: [scope])
        } else if mode == "initial-uid" {
          try $0.database.execute(sql: "UPDATE workspace SET uid=CAST(x'410042' AS TEXT)")
        } else {
          try $0.database.execute(
            sql:
              "CREATE TRIGGER refuse_decision BEFORE INSERT ON \(mode) BEGIN SELECT RAISE(ABORT,'fault'); END"
          )
        }
      }
      let before = try DocVerificationPreparationTests.truth(store)
      var failure: (any CodedError)?
      do {
        _ = try await DocTriageService(environment: env, workspace: scope, approved: "Reject rules")
          .triage(DocTriage(accept: [], reject: [ref]))
      } catch let error as any CodedError { failure = error }
      if mode == "unsafe-scope" {
        #expect(failure == nil)
        let audit = try store.read { try String.fetchOne($0, sql: "SELECT command FROM approval") }
        #expect(audit?.contains("doc triage --reject ") == true && audit?.contains(ref) == true)
      } else {
        #expect(failure?.code == .env)
        if mode == "initial-uid" {
          #expect(failure?.next == ["silta backup"] && failure?.nextBy == .human)
        }
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      }
    }
  }
}
