import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocStoreTests {
  static let actor = ActorID.agent(tool: "codex", session: "acme")
  static let instant = AcmeDocAttachments.instant

  static func writer(_ tx: StorageTransaction, ids: any IDGenerator) -> DocStore {
    DocStore(workspace: 1, transaction: tx, actor: actor, ids: ids, at: instant)
  }

  static func accept(_ draft: DocDraft, in store: DatabaseStore, ids: any IDGenerator) throws
    -> DocRevision
  {
    try store.write { try writer($0, ids: ids).accept(draft) }
  }

  @Test func acceptedRevisionsPreserveMetadataAndStableAttachments() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let ids = SeededIDGenerator(seed: 71)
      var draft = DocDraft(slug: "push-rules", body: "Keep unknown categories visible.")
      draft.title = "Push rules"
      draft.about = ["service:push", "edge:api/service:push/sdk", "service:push"]
      let first = try Self.accept(draft, in: store, ids: ids)
      #expect(first.revision == 1 && first.baseRevision == nil)
      #expect(first.kind == "contract")
      #expect(first.about == ["edge:api/service:push/sdk", "service:push"])
      #expect(first.actor == Self.actor.description)
      let links = try store.read {
        try String.fetchAll($0, sql: "SELECT id || ':' || uid FROM link ORDER BY id")
      }
      let sequence = try store.read {
        try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key='change_seq'")
      }
      let second = try Self.accept(
        DocDraft(slug: "push-rules", body: "Prefer the fallback."), in: store, ids: ids)
      #expect(second.revision == 2 && second.baseRevision == 1)
      #expect(second.title == "Push rules" && second.kind == "contract")
      #expect(second.about == first.about)
      #expect(
        try store.read {
          try String.fetchAll($0, sql: "SELECT id || ':' || uid FROM link ORDER BY id")
        } == links)
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key='change_seq'")
        } == (sequence ?? 0) + 1)
      try store.read { (db: Database) throws in
        let old = try DocStore.revision("push-rules", revision: 1, workspace: 1, in: db)
        #expect(old.body == "Keep unknown categories visible." && old.about == first.about)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_verification") == 2)
        #expect(
          try String.fetchAll(db, sql: "SELECT app_shas FROM doc_verification") == ["[]", "[]"])
        #expect(
          try String.fetchOne(db, sql: "SELECT verified_at FROM doc") == "2023-11-14T22:13:20.000Z")
        #expect(
          try String.fetchOne(db, sql: "SELECT kind FROM change_log ORDER BY seq DESC LIMIT 1")
            == "doc")
      }
    }
  }

  @Test func noAcceptedBaselineRequiresAllMetadataAndAllocatesAboveProposals() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
              VALUES('proposal-doc',1,'rules','Unaccepted title','runbook','','');
            INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at,title,kind,about_refs)
              VALUES('proposal',1,7,'Pending','proposed','agent:codex:other','',
                'Unaccepted title','runbook','["service:push"]');
            """)
      }
      let ids = SeededIDGenerator(seed: 71)
      for slug in ["rules", "new-rules"] {
        let before = try Self.snapshot(store)
        do {
          _ = try Self.accept(DocDraft(slug: slug, body: "Accepted body"), in: store, ids: ids)
          Issue.record("Incomplete metadata was accepted")
        } catch let error as any CodedError {
          #expect(error.code == .usage)
          #expect(error.message.contains("--title") && error.message.contains("--about"))
        }
        #expect(try Self.snapshot(store) == before)
      }
      var draft = DocDraft(slug: "rules", body: "Accepted body")
      draft.title = "Reviewed title"
      draft.about = ["app:api"]
      let revision = try Self.accept(draft, in: store, ids: ids)
      #expect(revision.revision == 8 && revision.baseRevision == nil)
      #expect(revision.title == "Reviewed title" && revision.kind == "reference")
      #expect(
        try store.read { try String.fetchOne($0, sql: "SELECT state FROM doc_rev WHERE rev=7") }
          == "proposed")
    }
  }

  @Test func invalidMetadataAndTargetsRollBackEverything() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let ids = SeededIDGenerator(seed: 71)
      var initial = DocDraft(slug: "rules", body: "First")
      initial.title = "Rules"
      initial.about = ["service:push"]
      _ = try Self.accept(initial, in: store, ids: ids)
      let before = try Self.snapshot(store)
      var empty = DocDraft(slug: "rules", body: "Rejected")
      empty.about = []
      var missing = empty
      missing.about = ["app:api", "service:missing"]
      var badKind = initial
      badKind.kind = "guide"
      var blankTitle = initial
      blankTitle.title = "  "
      var badSlug = initial
      badSlug.slug = "bad slug"
      for draft in [empty, missing, badKind, blankTitle, badSlug] {
        #expect(throws: (any Error).self) { _ = try Self.accept(draft, in: store, ids: ids) }
        #expect(try Self.snapshot(store) == before)
      }
    }
  }

  @Test func lateVerificationFailureRollsBackProjectionLinksHistoryAndChangeLog() throws {
    try withScratchDirectory { scratch in
      let store = try AcmeDocAttachments.make(in: scratch)
      let ids = SeededIDGenerator(seed: 71)
      var draft = DocDraft(slug: "rules", body: "First")
      draft.title = "Rules"
      draft.about = ["service:push"]
      _ = try Self.accept(draft, in: store, ids: ids)
      let collision = try SeededIDGenerator(seed: 99).next(at: Self.instant)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_verification SET uid=?", arguments: [collision])
      }
      let before = try Self.snapshot(store)
      let repeating = RepeatedIDs(value: collision)
      draft.body = "Must roll back"
      draft.title = "Must roll back"
      draft.about = ["app:api"]
      #expect(throws: (any Error).self) { _ = try Self.accept(draft, in: store, ids: repeating) }
      #expect(repeating.calls == 3)
      #expect(try Self.snapshot(store) == before)
    }
  }

  @Test func legacyUnknownHistoryIsNeverFilledFromCurrentProjection() throws {
    try withScratchDirectory { home in
      let store = try DocsMigrationTests.copyFixture(to: home)
      try store.initialize()
      let ids = SeededIDGenerator(seed: 71)
      try store.write { tx in
        try tx.database.execute(
          sql: "ALTER TABLE doc ADD COLUMN future TEXT; UPDATE doc SET owner='acme',future='keep';")
      }
      _ = try Self.accept(DocDraft(slug: "push-rules", body: "A newer rule"), in: store, ids: ids)
      try store.read { (db: Database) throws in
        let old = try DocStore.revision("push-rules", revision: 1, workspace: 1, in: db)
        #expect(old.title == nil && old.kind == nil && old.about == nil)
        #expect(old.body == "Original rule.")
        #expect(
          try String.fetchOne(db, sql: "SELECT owner || ':' || future FROM doc") == "acme:keep")
        #expect(
          try String.fetchOne(db, sql: "SELECT future FROM doc_rev WHERE rev=1")
            == "retained history")
      }
    }
  }

  static func snapshot(_ store: DatabaseStore) throws -> [[String]] {
    try store.read { (db: Database) throws in
      try ["doc", "doc_rev", "doc_verification", "link", "change_log", "meta"].map {
        try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid").map(\.description)
      }
    }
  }
}

private final class RepeatedIDs: IDGenerator {
  let value: String
  private let count = Mutex(0)
  var calls: Int { count.withLock { $0 } }
  init(value: String) { self.value = value }
  func next(at timestamp: Date) throws -> String {
    count.withLock { $0 += 1 }
    return value
  }
}
