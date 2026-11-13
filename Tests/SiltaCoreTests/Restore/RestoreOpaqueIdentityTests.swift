import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreOpaqueIdentityTests {
  @Test func actualDocumentOwnersAndIndependentFloorsRoundTripLiterally() throws {
    try withScratchDirectory { home in
      let store = try RestoreOpaqueIdentityFixture.documents(home)
      let before = try RestoreSupport.dump(store)
      try store.read { db in
        let rows = try String.fetchAll(
          db, sql: "SELECT uid FROM doc WHERE workspace_id=17 ORDER BY id")
        try #require(rows.count == 2)
        #expect(Set(rows.map { Data($0.utf8) }).count == 2)
        #expect(rows[0] == rows[1])
        #expect(try String.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil)
      }
      let tree = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
      let rows = tree.documents.commentSequences.filter {
        ($0.value("doc_rev") ?? "").hasPrefix("rev-caf")
      }
      Golden.forTests().check(ExportFormat.jsonl(rows), "restore-opaque-comment-floors.jsonl")
      let files = try tree.documents.files()
      #expect(try ExportDocumentSnapshot.parse(files, workspace: "acme") == tree.documents)
      #expect(try RestoreSupport.dump(store) == before)
      let expected = try RestoreDocumentRowSupport.replace(
        store, tree: tree, incoming: tree.documents)
      let after = try ExportDocumentSnapshotTests.read(store)
      ExportTreeTests.expectSame(try after.files(), try expected.files())
      let published = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      #expect(published.documents.documents.count == 2)
    }
  }

  @Test func baseReferencesAndMachineIdentitiesSurviveRealReplacement() throws {
    try withScratchDirectory { scratch in
      let source = try RestoreOpaqueIdentityFixture.base(scratch.appending(path: "source"))
      let home = scratch.appending(path: "target")
      let target = try RestoreOpaqueIdentityFixture.base(home, offset: 100)
      try source.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET uid=? WHERE slug='acme'",
          arguments: [RestoreOpaqueIdentityFixture.nfc("workspace")])
      }
      try target.write {
        try $0.database.execute(
          sql: "UPDATE workspace SET uid=? WHERE slug='acme'",
          arguments: [RestoreOpaqueIdentityFixture.nfd("workspace")])
      }
      let files = try ExportTreeTests.render(source)
      let tree = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      let machine = try RestoreOpaqueIdentityFixture.machineRows(target)
      let report = try RestoreSupport.restore(tree, into: target, home: home)
      #expect(report.changed.isEmpty && report.removed.isEmpty)
      #expect(!report.sameUID)
      ExportTreeTests.expectSame(try ExportTreeTests.render(target), files)
      #expect(try RestoreOpaqueIdentityFixture.machineRows(target) == machine)
    }
  }

  @Test func aCanonicalLookalikeDoesNotOwnAnotherDocumentsLiveLinks() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            UPDATE doc SET uid=:first,archived=0 WHERE id=91;
            INSERT INTO doc(uid,workspace_id,slug,title,kind,created_at,updated_at)
            VALUES(:second,17,'pending-only','Pending','contract','','');
            """,
          arguments: [
            "first": RestoreOpaqueIdentityFixture.nfc("doc"),
            "second": RestoreOpaqueIdentityFixture.nfd("doc"),
          ])
      }
      let tree = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      #expect(tree.documents.documents.count == 2)
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
    }
  }

  @Test func threadOwnersCannotBorrowCanonicalRevisionLookalikes() throws {
    try withScratchDirectory { home in
      let store = try RestoreOpaqueIdentityFixture.documents(home)
      try store.write {
        try $0.database.execute(sql: "UPDATE comment SET thread_id=44 WHERE uid='comment-child'")
      }
      let before = try RestoreSupport.dump(store)
      let tree = try store.read { try ExportSnapshot.capture($0, workspace: "acme") }
      #expect(
        throws: ExportError.invalidTree(
          reason: "a comment thread is cyclic or belongs to another owner", workspace: "acme")
      ) {
        try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
      }
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test func directRecordOwnerAndSourceReferencesRequireTheExactUID() throws {
    var tree = try RestoreDocumentGraphFixture.graph().tree
    let nfc = RestoreOpaqueIdentityFixture.nfc("rev")
    let nfd = RestoreOpaqueIdentityFixture.nfd("rev")
    RestoreOpaqueIdentityFixture.rename(&tree, from: ExportDocumentTests.uid("003"), to: nfc)
    RestoreDocumentGraphFixture.record(&tree.documents, 5, "doc_rev", nfd)
    #expect(
      throws: ExportError.invalidTree(
        reason: "a document record names a revision outside its document", workspace: "acme")
    ) {
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
    }
    tree = try RestoreDocumentGraphFixture.graph().tree
    RestoreOpaqueIdentityFixture.rename(
      &tree, from: ExportDocumentTests.uid("010"),
      to: RestoreOpaqueIdentityFixture.nfc("task"))
    RestoreDocumentGraphFixture.record(
      &tree.documents, 1, "source_task", RestoreOpaqueIdentityFixture.nfd("task"))
    #expect(
      throws: ExportError.invalidTree(
        reason: "a document revision names a source task outside the workspace", workspace: "acme"
      )
    ) {
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
    }
  }
}
