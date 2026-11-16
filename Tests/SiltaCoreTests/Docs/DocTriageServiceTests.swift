import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageServiceTests {
  static func environment(
    _ home: URL, _ store: DatabaseStore, git: any GitRunner = ScriptedGitRunner(script: []),
    human: Bool = false
  ) throws -> SiltaEnvironment {
    let base = try DocWritePolicyTests.service(home, store, human: human, approved: nil).environment
    return SiltaEnvironment(
      clock: base.clock, ids: base.ids, git: git, home: base.home,
      db: store, log: base.log, actor: base.actor, human: base.human)
  }

  static func propose(_ env: SiltaEnvironment, about: String, slug: String = "rules") throws -> String {
    try DocProposalService(environment: env, workspace: "acme").propose(
      DocProposalRequest(slug: slug, title: "Rules", about: [about], why: "Share."),
      input: { "Shared café." }).ref
  }

  @Test(arguments: [false, true])
  func rejectedHistoryNeedsNoLiveMetadataSourceTargetOrBodyAdmission(human: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try Self.environment(home, store, human: human)
      try DocProposalServiceTests.task(store, seq: 1, actor: env.actor.description)
      let ref = try Self.propose(env, about: "service:push")
      let body = Data(("Password=private123 " + String(repeating: "é", count: 40_000) + "\u{0}end").utf8)
      try store.write {
        try $0.database.execute(sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
          UPDATE task SET workspace_id=2;
          UPDATE doc_rev SET title=NULL,kind=NULL,about_refs=NULL,about_targets=NULL,body_md=CAST(? AS TEXT)
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
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc WHERE current_rev IS NOT NULL") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_verification") == 0)
        #expect(try Row.fetchAll(db, sql: "SELECT * FROM seq_counter") == before)
        #expect(try String.fetchOne(db, sql: "SELECT triaged_by FROM doc_rev") == env.actor.description)
      }
    }
  }

  @Test(arguments: ["app", "service", "topic", "edge"], [false, true])
  func acceptanceFollowsUIDRenamesAndRefusesReplacements(kind: String, replace: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try Self.environment(home, store)
      let old = kind == "edge" ? "edge:api/service:push/sdk"
        : kind + ":" + (kind == "app" ? "api" : kind == "service" ? "push" : "messaging")
      let ref = try Self.propose(env, about: old)
      try store.write {
        try $0.database.execute(sql: replace ? "UPDATE \(kind) SET uid='replacement'"
          : kind == "edge" ? "UPDATE edge SET kind='HTTP API'" : "UPDATE \(kind) SET slug='renamed'")
      }
      let before = try DocVerificationPreparationTests.truth(store)
      do {
        _ = try await DocTriageService(
          environment: env, workspace: "acme", approved: "Accept Acme rules"
        ).triage(DocTriage(accept: [ref], reject: []))
        #expect(!replace)
      } catch let error as any CodedError {
        #expect(replace && error.code == .conflict)
      }
      if replace {
        #expect(try DocVerificationPreparationTests.truth(store) == before)
      } else {
        try store.read { (db: Database) throws in
          let target = try #require(try DocStore.attachments(1, workspace: 1, in: db).first)
          let expected = kind == "edge" ? "edge:api/service:push/HTTP%20API" : kind + ":renamed"
          #expect(try TaskLinkTarget.render(target, in: db) == expected)
          #expect(try String.fetchOne(db, sql: "SELECT about_refs FROM doc_rev") == "[\"" + old + "\"]")
          #expect(try Int.fetchOne(db, sql: "SELECT current_rev FROM doc") == 1)
          let verified = try String.fetchOne(db, sql: "SELECT verified_at FROM doc")
          #expect((verified == nil) == ["app", "edge"].contains(kind))
        }
      }
    }
  }

  @Test(arguments: [
    "body", "unicode-body", "reject-body", "revision", "state", "source",
    "app", "edge", "service", "repo", "path", "ref", "workspace",
  ])
  func everyMemberAndAcceptanceBindingIsRecheckedBeforeWriting(change: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let expected = Mutex<[[Row]]?>(nil)
      let runner = ScriptedGitRunner(
        script: [(DocVerificationPreparationTests.request("origin/api", repo: repo),
          DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA))],
        beforeRequest: { _ in
          try Self.mutate(change, store: store)
          let truth = try DocVerificationPreparationTests.truth(store)
          expected.withLock { $0 = truth }
        })
      let env = try Self.environment(home, store, git: runner)
      try DocProposalServiceTests.task(store, seq: 80, actor: env.actor.description)
      let accept = try Self.propose(env, about: "edge:api/service:push/sdk")
      let reject = try Self.propose(env, about: "topic:messaging", slug: "obsolete")
      do {
        _ = try await DocTriageService(
          environment: env, workspace: "acme", approved: "Review Acme rules"
        ).triage(DocTriage(accept: [accept], reject: [reject]))
        Issue.record("Changed batch was decided")
      } catch let error as any CodedError {
        #expect(error.code == .conflict)
      }
      #expect(runner.isExhausted)
      #expect(try DocVerificationPreparationTests.truth(store) == expected.withLock { $0 })
    }
  }

  private static func mutate(_ change: String, store: DatabaseStore) throws {
    let statements = [
      "body": "UPDATE doc_rev SET body_md='changed' WHERE rev=1 AND doc_id=1",
      "unicode-body": "UPDATE doc_rev SET body_md='Shared cafe\u{301}.' WHERE doc_id=1",
      "reject-body": "UPDATE doc_rev SET body_md='changed reject' WHERE doc_id=2",
      "revision": "UPDATE doc_rev SET uid='replacement-revision' WHERE doc_id=1",
      "state": "UPDATE doc_rev SET state='rejected' WHERE doc_id=1",
      "source": "UPDATE task SET uid='replacement-source' WHERE seq=80",
      "app": "UPDATE app SET uid='replacement-app' WHERE slug='api'",
      "edge": "UPDATE edge SET uid='replacement-edge' WHERE kind='sdk'",
      "service": "UPDATE service SET uid='replacement-service' WHERE slug='push'",
      "repo": "UPDATE repo SET uid='replacement-repo'",
      "path": "UPDATE repo_path SET path='/acme/changed'",
      "ref": "UPDATE app SET ref='origin/new' WHERE slug='api'",
      "workspace": "UPDATE workspace SET uid='replacement-workspace' WHERE slug='acme'",
    ]
    let sql = try #require(statements[change])
    try store.write { try $0.database.execute(sql: sql) }
  }
}
