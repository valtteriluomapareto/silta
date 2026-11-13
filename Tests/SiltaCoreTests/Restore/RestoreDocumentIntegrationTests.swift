import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentIntegrationTests {
  static func source(_ home: URL) throws -> DatabaseStore {
    let store = try RestoreDocumentGraphFixture.source(home)
    try store.write {
      try $0.database.execute(
        sql: """
          UPDATE task SET claimed_by='agent:codex:acme',claimed_at='2023-11-14T22:13:00.000Z',
            branch='feature/docs' WHERE id=700;
          INSERT INTO seq_counter(scope,next) VALUES('task:17',2);
          UPDATE task SET plan_rev=2,plan_md='v2' WHERE id=700;
          INSERT INTO task_plan_rev(id,task_id,rev,body_md,actor,created_at)
          VALUES(1601,700,1,'v1','human:acme',''),(1602,700,2,'v2','human:acme','');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,
            created_by,created_at)
          VALUES('note-nfc',17,'task',700,'cites','note',:nfc,'human:acme',''),
            ('note-nfd',17,'task',700,'cites','note',:nfd,'human:acme','');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
            created_by,created_at)
          VALUES('plan-one',17,'task',700,'cites','task_plan_rev',1601,'human:acme',''),
            ('plan-two',17,'task',700,'cites','task_plan_rev',1602,'human:acme','');
          """, arguments: ["nfc": "caf\u{e9}", "nfd": "cafe\u{301}"])
    }
    return store
  }

  static func publish(_ store: DatabaseStore, home: URL, to root: URL) throws -> URL {
    _ = try ExportService.export(workspace: "acme", to: root, store: store, home: home)
    return root.appending(path: "acme")
  }

  @Test func publicPublicationAndFreshRestoreKeepCompleteLiteralTruth() throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try Self.source(sourceHome)
      let before = try RestoreSupport.dump(source)
      let directory = try Self.publish(source, home: sourceHome, to: scratch.appending(path: "out"))
      let files = try RestoreService.readTree(directory)
      let parsed = try ExportTree.parse(files)
      #expect(parsed.documents.documents.count == 1)
      ExportTreeTests.expectSame(
        try parsed.documents.files(), try ExportDocumentSnapshotTests.golden())
      #expect(Array(parsed.links.prefix(10)) == (try RestoreDocumentGraphFixture.links()))
      let notes = parsed.links.filter { $0.value("to_kind") == "note" }
      #expect(
        notes.compactMap { $0.value("to_ext").map { Data($0.utf8) } }
          == [Data("caf\u{e9}".utf8), Data("cafe\u{301}".utf8)])
      #expect(
        parsed.links.filter { $0.value("to_kind") == "task_plan_rev" }
          .compactMap { $0.value("to_rev") } == ["1", "2"])
      #expect(try RestoreSupport.dump(source) == before)
      let home = scratch.appending(path: "target")
      let target = ExportFixture.store(home)
      try target.initialize()
      let empty = try RestoreSupport.dump(target)
      let preview = try RestoreSupport.restore(directory, into: target, home: home, dryRun: true)
      #expect(preview.docs == RestoreReport.Counts(before: 0, after: 1))
      #expect(try RestoreSupport.dump(target) == empty)
      let report = try RestoreSupport.restore(directory, into: target, home: home)
      #expect(report.created && report.docs.after == 1)
      ExportTreeTests.expectSame(try ExportTreeTests.render(target), files)
      try target.read { (db: Database) throws in
        #expect(try Int64.fetchOne(db, sql: "SELECT id FROM doc") != 91)
        #expect(try Int64.fetchOne(db, sql: "SELECT id FROM task") != 700)
        #expect(try String.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil)
      }
    }
  }

  @Test func olderPublicRestoreMergesReservationsAndRemapsIncomingComments() throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try Self.source(sourceHome)
      let directory = try Self.publish(source, home: sourceHome, to: scratch.appending(path: "out"))
      let home = scratch.appending(path: "target")
      let target = try RestoreDocumentRowSupport.make(home)
      let retained = try Self.retained(target)
      let before = try RestoreSupport.dump(target)
      let preview = try RestoreSupport.restore(directory, into: target, home: home, dryRun: true)
      #expect(preview.docs == RestoreReport.Counts(before: 2, after: 1))
      #expect(preview.changedDocs == ["doc:push-rules"])
      #expect(preview.removedDocs == ["doc:removed-rules"])
      #expect(try RestoreSupport.dump(target) == before)
      let old = try target.read { db in
        try Int64.fetchAll(db, sql: "SELECT id FROM comment WHERE doc_rev_id=901 ORDER BY id")
      }
      _ = try RestoreSupport.restore(directory, into: target, home: home)
      #expect(try Self.retained(target) == retained)
      let restored = try ExportTreeTests.render(target)
      Golden.forTests().check(
        text(try #require(restored[ExportFormat.docAllocationsFile])),
        "restore-doc-allocations.jsonl")
      let tree = try ExportTree.parse(restored)
      let incoming = try ExportDocumentSnapshotTests.read(source)
      #expect(tree.documents.documents == incoming.documents)
      #expect(tree.documents.commentSequences == incoming.commentSequences)
      try target.read { db in
        #expect(
          try Int64.fetchOne(
            db, sql: "SELECT count(*) FROM seq_counter WHERE scope='comment:doc_rev:901'") == 0)
        let new = try Int64.fetchAll(
          db, sql: "SELECT id FROM comment WHERE doc_rev_id IS NOT NULL ORDER BY id")
        let changes = try Int64.fetchAll(
          db, sql: "SELECT row_id FROM change_log WHERE kind='comment'")
        #expect(Set(old + new).isSubset(of: Set(changes)))
        let doc = try #require(
          try Int64.fetchOne(db, sql: "SELECT id FROM doc WHERE workspace_id=17"))
        let docs = try Int64.fetchAll(db, sql: "SELECT row_id FROM change_log WHERE kind='doc'")
        #expect(Set([91, 100, doc]).isSubset(of: Set(docs)))
      }
      let ids = SeededIDGenerator(seed: 77)
      #expect(
        try RestoreDocumentRowSupport.accept("push-rules", store: target, ids: ids).revision == 151)
      #expect(
        try RestoreDocumentRowSupport.accept("removed-rules", store: target, ids: ids).revision
          == 236)
      #expect(try Self.commentSequence(target) == 9)
    }
  }

  @Test func publicRestoreRepairsProjectionAndRollsBackLateReadbackFailure() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try Self.source(home)
      let directory = try Self.publish(store, home: home, to: scratch.appending(path: "out"))
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET title='Broken projection' WHERE id=91")
      }
      _ = try RestoreSupport.restore(directory, into: store, home: home)
      let document = try #require(try ExportDocumentSnapshotTests.read(store).documents.first)
      #expect(document.row.value("title") == "Push fallback")
      var tree = try ExportTree.parse(RestoreService.readTree(directory))
      try #require(!tree.tasks.isEmpty)
      tree.tasks[0].row = tree.tasks[0].row.replacing(
        "priority", with: "01", keys: ExportFormat.taskKeys)
      let damaged = try RestoreSupport.write(
        tree.files(), to: scratch.appending(path: "damaged/acme"))
      let before = try RestoreSupport.dump(store)
      for dryRun in [false, true] {
        do {
          _ = try RestoreSupport.restore(damaged, into: store, home: home, dryRun: dryRun)
          Issue.record("Accepted a late stored-value normalization mismatch")
        } catch let error as ExportError {
          #expect(error.code == .invalid)
          #expect(error.message.contains("does not come back the same after restoring"))
        }
        #expect(try RestoreSupport.dump(store) == before)
      }
    }
  }

  private static func commentSequence(_ store: DatabaseStore) throws -> Int64 {
    let owner = try #require(
      try store.read {
        try Int64.fetchOne(
          $0, sql: "SELECT id FROM doc_rev WHERE uid=?",
          arguments: [ExportDocumentTests.uid("003")])
      })
    return try store.write { try $0.nextSequence(scope: "comment:doc_rev:\(owner)") }
  }

  private static func retained(_ store: DatabaseStore) throws -> [[String]] {
    let queries = [
      "SELECT * FROM workspace WHERE id=23", "SELECT * FROM doc WHERE workspace_id=23",
      "SELECT * FROM doc_rev WHERE doc_id=92", "SELECT * FROM link WHERE workspace_id=23",
      """
      SELECT * FROM seq_counter WHERE scope IN
        ('doc_rev:23:gone-rules','comment:doc_rev:950','comment:doc_rev:4040404')
      """,
      "SELECT r.uid,p.path,p.fetched_at FROM repo_path p JOIN repo r ON r.id=p.repo_id",
      "SELECT a.uid,o.path,o.set_by FROM worktree_override o JOIN app a ON a.id=o.app_id",
      "SELECT uid,worktree,claimed_by,claimed_at,branch FROM task WHERE workspace_id=17",
    ]
    return try store.read { db in
      try queries.map { try Row.fetchAll(db, sql: $0).map(\.description) }
    }
  }
}
