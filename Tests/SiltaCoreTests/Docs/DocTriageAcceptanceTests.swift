import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTriageAcceptanceTests {
  @Test(arguments: ["app", "service", "topic", "edge"], [false, true])
  func acceptanceFollowsUIDRenamesAndRefusesReplacements(kind: String, replace: Bool) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try DocTriageServiceTests.environment(home, store)
      let old =
        kind == "edge"
        ? "edge:api/service:push/sdk"
        : kind + ":" + (kind == "app" ? "api" : kind == "service" ? "push" : "messaging")
      let ref = try DocTriageServiceTests.propose(env, about: old)
      try store.write {
        try $0.database.execute(
          sql: replace
            ? "UPDATE \(kind) SET uid='replacement'"
            : kind == "edge"
              ? "UPDATE edge SET kind='HTTP API'" : "UPDATE \(kind) SET slug='renamed'")
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
          #expect(
            try String.fetchOne(db, sql: "SELECT about_refs FROM doc_rev") == "[\"" + old + "\"]")
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
    "accepted-body", "accepted-title", "accepted-pointer",
  ])
  func everyMemberAndAcceptanceBindingIsRecheckedBeforeWriting(change: String) async throws {
    try await withScratchDirectory { home in
      let (store, repo) = try DocVerificationPreparationTests.setup(home)
      let expected = Mutex<[[String]]?>(nil)
      let runner = ScriptedGitRunner(
        script: [
          (
            DocVerificationPreparationTests.request("origin/api", repo: repo),
            DocVerificationPreparationTests.result(DocVerificationPreparationTests.apiSHA)
          )
        ],
        beforeRequest: { _ in
          try Self.mutate(change, store: store)
          let truth = try DocVerificationPreparationTests.truth(store)
          expected.withLock { $0 = truth }
        })
      let env = try DocTriageServiceTests.environment(home, store, git: runner)
      if change.hasPrefix("accepted-") {
        try DocWritePolicyTests.seed(store, body: "Shared café.", seed: 95)
      }
      try DocProposalServiceTests.task(store, seq: 80, actor: env.actor.description)
      let accept = try DocTriageServiceTests.propose(env, about: "edge:api/service:push/sdk")
      let reject = try DocTriageServiceTests.propose(
        env, about: "topic:messaging", slug: "obsolete")
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

  @Test(arguments: [
    "stale", "overlap", "unknown", "source", "decided", "foreign",
    "doc_verification", "approval",
  ])
  func invalidAcceptanceAndLateFailuresLeaveTheWholeBatchUntouched(fault: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try DocTriageServiceTests.environment(home, store)
      try DocProposalServiceTests.task(store, seq: 1, actor: env.actor.description)
      let first = try DocTriageServiceTests.propose(env, about: "service:push")
      let second = try DocTriageServiceTests.propose(env, about: "service:push")
      if fault == "stale" {
        _ = try await DocWriteService(environment: env, workspace: "acme", approved: "Update rules")
          .edit(
            DocEditRequest(slug: "rules", title: "Rules", about: ["service:push"]),
            input: { "Updated." })
      }
      try Self.install(fault, in: store)
      let before = try DocVerificationPreparationTests.truth(store)
      let expected: ErrorCode =
        fault == "stale"
        ? .staleRev
        : fault == "foreign"
          ? .notFound
          : ["doc_verification", "approval"].contains(fault)
            ? .env
            : fault == "decided" ? .invalid : .conflict
      await DocWritePolicyTests.refusal(expected) {
        _ = try await DocTriageService(
          environment: env, workspace: "acme", approved: "Review rules"
        )
        .triage(
          DocTriage(
            accept: fault == "overlap" ? [first, second] : [first],
            reject: fault == "overlap" ? [] : [second]))
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  private static func install(_ fault: String, in store: DatabaseStore) throws {
    try store.write { tx in
      let sql = [
        "unknown": "UPDATE doc_rev SET about_targets=NULL WHERE rev=1",
        "source": "UPDATE task SET workspace_id=99",
        "decided": "UPDATE doc_rev SET state='rejected' WHERE rev=1",
        "foreign": "UPDATE doc SET workspace_id=99",
      ][fault]
      if let sql {
        if ["foreign", "source"].contains(fault) {
          try tx.database.execute(
            sql: """
              INSERT INTO workspace(id,uid,slug,name,task_prefix)
              VALUES(99,'beta','beta','Beta','BE')
              """
          )
        }
        try tx.database.execute(sql: sql)
      }
      if ["doc_verification", "approval"].contains(fault) {
        try tx.database.execute(
          sql:
            "CREATE TRIGGER fail_decision BEFORE INSERT ON \(fault) BEGIN SELECT RAISE(ABORT,'decision fault'); END"
        )
      }
    }
  }

  private static func mutate(_ change: String, store: DatabaseStore) throws {
    let rules = "(SELECT id FROM doc WHERE slug='rules')"
    let obsolete = "(SELECT id FROM doc WHERE slug='obsolete')"
    let statements = [
      "accepted-body":
        "UPDATE doc_rev SET body_md='Shared cafe\u{301}.' WHERE rev=1 AND doc_id=\(rules)",
      "accepted-title": "UPDATE doc SET title='Changed' WHERE slug='rules'",
      "accepted-pointer": "UPDATE doc SET current_rev=NULL WHERE slug='rules'",
      "body":
        "UPDATE doc_rev SET body_md='changed' WHERE rev=1 AND doc_id=\(rules)",
      "unicode-body":
        "UPDATE doc_rev SET body_md='Shared cafe\u{301}.' WHERE doc_id=\(rules)",
      "reject-body":
        "UPDATE doc_rev SET body_md='changed reject' WHERE doc_id=\(obsolete)",
      "revision":
        "UPDATE doc_rev SET uid='replacement-revision' WHERE doc_id=\(rules)",
      "state":
        "UPDATE doc_rev SET state='rejected' WHERE doc_id=\(rules)",
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
