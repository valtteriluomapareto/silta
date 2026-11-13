import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreSnapshotPreflightTests {
  @Test(arguments: ["doc", "doc_rev", "doc_verification", "task-comment", "doc-comment", "doc-comment-doc"])
  func foreignUIDsRefuseBeforeAnyWrite(_ kind: String) throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try Self.foreignRows(store)
      var graph = try RestoreDocumentGraphFixture.graph()
      graph.tree.documents = graph.documents
      try store.write(rollingBack: true) { tx in
        var writer = RestoreWriter(tx: tx, tree: graph.tree, slug: "acme")
        writer.workspace = 17
        try writer.checkForeignUIDs()
      }
      switch kind {
      case "doc":
        graph.tree.documents.documents[0].row = graph.tree.documents.documents[0].row.replacing(
          "uid", with: "other-doc", keys: ExportFormat.docKeys)
      case "doc_rev":
        RestoreDocumentGraphFixture.record(&graph.tree.documents, 0, "uid", "other-revision")
      case "doc_verification":
        RestoreDocumentGraphFixture.record(&graph.tree.documents, 5, "uid", "foreign-verification")
      case "task-comment":
        var row = try #require(graph.tree.tasks[0].records.first { $0.value("table") == "comment" })
        row = row.replacing("uid", with: "foreign-doc-comment", keys: ExportFormat.records[2].keys)
        graph.tree.tasks[0].records = [row]
      default:
        let uid = kind == "doc-comment" ? "foreign-task-comment" : "foreign-doc-comment"
        RestoreDocumentGraphFixture.record(&graph.tree.documents, 6, "uid", uid)
      }
      let before = try RestoreSupport.dump(store)
      try store.write(rollingBack: true) { tx in
        var writer = RestoreWriter(tx: tx, tree: graph.tree, slug: "acme")
        writer.workspace = 17
        do {
          try writer.checkForeignUIDs()
          Issue.record("Accepted a foreign-workspace \(kind) UID")
        } catch let error as ExportError {
          #expect(error.code == "conflict")
        }
      }
      #expect(try RestoreSupport.dump(store) == before)
    }
  }

  @Test func byteDistinctForeignUIDDoesNotBlockReplacement() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET uid=? WHERE id=92", arguments: ["cafe\u{301}"])
      }
      var graph = try RestoreDocumentGraphFixture.graph()
      graph.tree.documents = graph.documents
      graph.tree.documents.documents[0].row = graph.tree.documents.documents[0].row.replacing(
        "uid", with: "caf\u{e9}", keys: ExportFormat.docKeys)
      try store.write(rollingBack: true) { tx in
        var writer = RestoreWriter(tx: tx, tree: graph.tree, slug: "acme")
        writer.workspace = 17
        try writer.checkForeignUIDs()
      }
    }
  }

  @Test func removedIDsIncludeBothCommentOwnersAndOnlyOwnedDocuments() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentRowSupport.make(home)
      try Self.foreignRows(store)
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO comment(id,uid,task_id,seq,kind,body_md,actor,created_at)
            VALUES(2000,'owned-task-comment',700,1,'comment','','human:acme','')
            """)
      }
      let tree = try RestoreDocumentGraphFixture.graph().tree
      try store.write(rollingBack: true) { tx in
        var writer = RestoreWriter(tx: tx, tree: tree, slug: "acme")
        writer.workspace = 17
        let old = try writer.removedIDs()
        #expect(old.docs == [91, 100])
        #expect(old.tasks == [700])
        #expect(old.comments == [44, 45, 46, 2000])
      }
    }
  }

  private static func foreignRows(_ store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO doc_verification(uid,doc_rev_id,actor,app_shas,created_at)
          VALUES('foreign-verification',950,'human:other','[]','');
          INSERT INTO task(id,uid,workspace_id,seq,title,created_by,created_at,updated_at)
          VALUES(2700,'foreign-task',23,1,'Other task','human:other','','');
          INSERT INTO comment(uid,doc_rev_id,seq,kind,body_md,actor,created_at)
          VALUES('foreign-doc-comment',950,1,'comment','','human:other','');
          INSERT INTO comment(uid,task_id,seq,kind,body_md,actor,created_at)
          VALUES('foreign-task-comment',2700,1,'comment','','human:other','');
          """)
    }
  }
}
