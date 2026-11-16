import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageServiceTests {
  static func environment(
    _ home: URL, _ store: DatabaseStore, git: any GitRunner = ScriptedGitRunner(script: []),
    human: Bool = false
  ) throws -> SiltaEnvironment {
    try DocWritePolicyTests.service(home, store, human: human, approved: nil, git: git).environment
  }

  static func propose(_ env: SiltaEnvironment, about: String, slug: String = "rules") throws
    -> String
  {
    try DocProposalService(environment: env, workspace: "acme").propose(
      DocProposalRequest(slug: slug, title: "Rules", about: [about], why: "Share."),
      input: { "Shared café." }
    ).ref
  }

  @Test(arguments: [false, true])
  func rejectedHistoryNeedsNoLiveMetadataSourceTargetOrBodyAdmission(human: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try Self.environment(home, store, human: human)
      try DocProposalServiceTests.task(store, seq: 1, actor: env.actor.description)
      let ref = try Self.propose(env, about: "service:push")
      let body = Data(
        ("Password=private123 " + String(repeating: "é", count: 40_000) + "\u{0}end").utf8)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
            UPDATE task SET workspace_id=2;
            UPDATE doc_rev SET title=NULL,kind=NULL,about_refs=NULL,about_targets=NULL,
            body_md=CAST(? AS TEXT)
            """, arguments: [body])
      }
      try AcmeDocAttachments.apply(AcmeDocAttachments.yaml(removing: "service"), to: store)
      let before = try store.read { try Row.fetchAll($0, sql: "SELECT * FROM seq_counter") }
      let result = try await DocTriageService(
        environment: env, workspace: "acme", approved: human ? nil : "Reject obsolete Acme rules"
      ).triage(DocTriage(accept: [], reject: [ref]))
      #expect(result.docs.map(\.state) == ["rejected"])
      try store.read { (db: Database) throws in
        #expect(try Data.fetchOne(db, sql: "SELECT CAST(body_md AS BLOB) FROM doc_rev") == body)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == (human ? 0 : 1))
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM doc WHERE current_rev IS NOT NULL") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_verification") == 0)
        #expect(try Row.fetchAll(db, sql: "SELECT * FROM seq_counter") == before)
        #expect(
          try String.fetchOne(db, sql: "SELECT triaged_by FROM doc_rev") == env.actor.description)
      }
    }
  }

}
