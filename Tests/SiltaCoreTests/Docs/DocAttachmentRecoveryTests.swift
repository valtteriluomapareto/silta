import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocAttachmentRecoveryTests {
  @Test func replacingAttachmentsAllowsRemovingOldEdgeAndKeepsHistory() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let ids = SeededIDGenerator(seed: 71)
      var draft = DocDraft(slug: "rules", body: "Use the fallback.")
      draft.title = "Push rules"
      draft.about = ["edge:api/service:push/sdk"]
      _ = try DocStoreTests.accept(draft, in: store, ids: ids)
      let both = AcmeDocAttachments.yaml().replacingOccurrences(
        of: "summary: Push}]",
        with: "summary: Push}, {from: api, to: service:push, kind: http-api, summary: HTTP}]")
      try AcmeDocAttachments.apply(both, to: store)
      draft.about = ["edge:api/service:push/http-api"]
      _ = try DocStoreTests.accept(draft, in: store, ids: ids)
      try AcmeDocAttachments.apply(
        AcmeDocAttachments.yaml().replacingOccurrences(of: "kind: sdk", with: "kind: http-api"),
        to: store)
      try store.read { db in
        #expect(try String.fetchAll(db, sql: "SELECT kind FROM edge") == ["http-api"])
        #expect(
          try DocStore.revision("rules", revision: 1, workspace: 1, in: db).about == [
            "edge:api/service:push/sdk"
          ])
        #expect(
          try DocStore.revision("rules", revision: 2, workspace: 1, in: db).about == draft.about)
      }
    }
  }

  @Test func archiveReleasesAttachmentsAndReactivationRequiresANewSet() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let ids = SeededIDGenerator(seed: 71)
      var draft = DocDraft(slug: "rules", body: "Keep the fallback.")
      draft.title = "Push rules"
      draft.about = ["service:push"]
      _ = try DocStoreTests.accept(draft, in: store, ids: ids)
      #expect(try store.write { try DocStoreTests.writer($0, ids: ids).archive("rules") })
      let archived = try DocStoreTests.snapshot(store)
      #expect(!(try store.write { try DocStoreTests.writer($0, ids: ids).archive("rules") }))
      #expect(try DocStoreTests.snapshot(store) == archived)
      try AcmeDocAttachments.apply(AcmeDocAttachments.yaml(removing: "service"), to: store)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM link WHERE rel='about'") }
          == 0)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_verification") } == 1)
      #expect(throws: (any Error).self) {
        _ = try DocStoreTests.accept(
          DocDraft(slug: "rules", body: "A new rule"), in: store, ids: ids)
      }
      draft.body = "A new rule"
      draft.about = ["topic:messaging"]
      let restored = try DocStoreTests.accept(draft, in: store, ids: ids)
      #expect(restored.revision == 2)
      #expect(try store.read { try Bool.fetchOne($0, sql: "SELECT archived FROM doc") } == false)
      #expect(
        try store.read { try DocStore.revision("rules", revision: 1, workspace: 1, in: $0).about }
          == ["service:push"])
    }
  }

  @Test func kindsAreInferredFromTheDeduplicatedAttachmentSetAndCanBeExplicit() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO edge(uid,workspace_id,from_app_id,to_service_id,kind,summary)
              VALUES('second-edge',1,1,1,'http-api','HTTP');
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('foreign',2,'foreign','Foreign');
            """)
      }
      let ids = SeededIDGenerator(seed: 71)
      let cases: [(String, [String])] = [
        ("runbook", ["service:push", "service:push"]),
        ("reference", ["app:api"]), ("reference", ["topic:messaging"]),
        ("contract", ["edge:api/service:push/sdk"]),
        ("flow", ["edge:api/service:push/sdk", "edge:api/service:push/http-api"]),
      ]
      for (index, item) in cases.enumerated() {
        var draft = DocDraft(slug: "rules-\(index)", body: "Rule")
        draft.title = "Rules"
        draft.about = item.1
        #expect(try DocStoreTests.accept(draft, in: store, ids: ids).kind == item.0)
      }
      var explicit = DocDraft(slug: "explicit", body: "Rule")
      explicit.title = "Rules"
      explicit.about = ["app:api"]
      explicit.kind = "flow"
      #expect(try DocStoreTests.accept(explicit, in: store, ids: ids).kind == "flow")
      explicit.about = ["service:foreign"]
      let before = try DocStoreTests.snapshot(store)
      #expect(throws: (any Error).self) {
        _ = try DocStoreTests.accept(explicit, in: store, ids: ids)
      }
      #expect(try DocStoreTests.snapshot(store) == before)
    }
  }
}
