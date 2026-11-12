import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocRevisionCounterTests {
  @Test func storedReservationsAreHonoredWithoutHistoryAndStayScoped() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let ids = SeededIDGenerator(seed: 71)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO seq_counter(scope,next) VALUES('doc_rev:1:rules',20);
            INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('beta','beta','Beta','BE');
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('beta-push',2,'push','Push');
            """)
      }
      var draft = DocDraft(slug: "rules", body: "Use the fallback.")
      draft.title = "Rules"
      draft.about = ["service:push"]
      #expect(try DocStoreTests.accept(draft, in: store, ids: ids).revision == 20)
      draft.slug = "other"
      #expect(try DocStoreTests.accept(draft, in: store, ids: ids).revision == 1)
      draft.slug = "rules"
      let beta = try store.write {
        try DocStore(
          workspace: 2, transaction: $0, actor: DocStoreTests.actor,
          ids: ids, at: DocStoreTests.instant
        ).accept(draft)
      }
      #expect(beta.revision == 1)
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT next FROM seq_counter WHERE scope='doc_rev:1:rules'")
        } == 21)
    }
  }

  @Test func historicalProposalMaximumBootstrapsTheReservation() throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      try store.initialize()
      let revision = try DocStoreTests.accept(
        DocDraft(slug: "push-rules", body: "A new rule"), in: store,
        ids: SeededIDGenerator(seed: 71))
      #expect(revision.revision == 4 && revision.baseRevision == 2)
      #expect(
        try store.read {
          try Int.fetchOne(
            $0, sql: "SELECT next FROM seq_counter WHERE scope='doc_rev:1:push-rules'")
        } == 5)
    }
  }

  @Test func exhaustedReservationIsCodedAndLeavesEverythingUnchanged() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: "INSERT INTO seq_counter(scope,next) VALUES(?,?)",
          arguments: ["doc_rev:1:rules", Int64.max])
      }
      let before = try DocStoreTests.snapshot(store)
      var draft = DocDraft(slug: "rules", body: "Must not be saved.")
      draft.title = "Rules"
      draft.about = ["service:push"]
      #expect(throws: StorageError.resourceExhausted) {
        _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: 71))
      }
      #expect(try DocStoreTests.snapshot(store) == before)
    }
  }
}
