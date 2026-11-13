import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestorePublicOpaqueIdentityTests {
  @Test(arguments: [false, true])
  func publicRoundtripKeepsDistinctOwnersAndLiteralFloors(_ inPlace: Bool) throws {
    try withScratchDirectory { scratch in
      let sourceHome = scratch.appending(path: "source")
      let source = try RestoreOpaqueIdentityFixture.documents(sourceHome)
      let identities = try Self.identities(source)
      let docUIDs = try source.read {
        try String.fetchAll($0, sql: "SELECT uid FROM doc WHERE workspace_id=17 ORDER BY id")
      }
      #expect(Set(docUIDs.map { Data($0.utf8) }).count == 2)
      let before = try RestoreSupport.dump(source)
      let directory = try RestoreDocumentIntegrationTests.publish(
        source, home: sourceHome, to: scratch.appending(path: "out"))
      let files = try RestoreService.readTree(directory)
      let tree = try ExportTree.parse(files)
      #expect(tree.documents.documents.count == 2)
      let floors = tree.documents.commentSequences.filter {
        ($0.value("doc_rev") ?? "").hasPrefix("rev-caf")
      }
      #expect(
        Data(ExportFormat.jsonl(floors).utf8)
          == Data(
            ("{\"doc_rev\": \"rev-cafe\u{301}\", \"next\": \"27\"}\n"
              + "{\"doc_rev\": \"rev-caf\u{e9}\", \"next\": \"13\"}\n").utf8))
      #expect(try RestoreSupport.dump(source) == before)
      let home = scratch.appending(path: "target")
      let target: DatabaseStore
      if inPlace {
        target = try RestoreOpaqueIdentityFixture.documents(home)
      } else {
        target = ExportFixture.store(home)
        try target.initialize()
      }
      let original = try RestoreSupport.dump(target)
      let preview = try RestoreSupport.restore(directory, into: target, home: home, dryRun: true)
      #expect(preview.docs == RestoreReport.Counts(before: inPlace ? 2 : 0, after: 2))
      #expect(try RestoreSupport.dump(target) == original)
      let report = try RestoreSupport.restore(directory, into: target, home: home)
      #expect(report.created == !inPlace && report.docs.after == 2)
      #expect(report.nextTaskRef.after == "AC-3")
      var expected = tree
      expected.workspace = tree.workspace.replacing(
        "next_task_seq", with: "3", keys: ExportFormat.workspaceKeys)
      ExportTreeTests.expectSame(try ExportTreeTests.render(target), try expected.files())
      #expect(try Self.identities(target) == identities)
      try target.read { (db: Database) throws in
        #expect(try String.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil)
        #expect(try Int64.fetchOne(db, sql: "SELECT id FROM doc WHERE slug='push-rules'") != 91)
      }
    }
  }

  @Test(
    arguments: [
      "ghp_" + String(repeating: "x", count: 36), String(repeating: "a", count: 52),
      "opaque-ordinary",
    ], [false, true])
  func publicForeignUIDConflictMasksDiagnosticsAndWritesNothing(_ uid: String, dryRun: Bool) throws
  {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let target = try RestoreDocumentRowSupport.make(home)
      try target.write {
        try $0.database.execute(sql: "UPDATE doc SET uid=? WHERE id=92", arguments: [uid])
      }
      var tree = try RestoreDocumentGraphFixture.graph().tree
      RestoreOpaqueIdentityFixture.rename(&tree, from: ExportDocumentTests.uid("001"), to: uid)
      try RestoreDocumentGraph(tree: tree, documents: tree.documents, slug: "acme").run()
      let files = try tree.files()
      #expect(try #require(files["docs/push-rules.md"]).range(of: Data(uid.utf8)) != nil)
      let directory = try RestoreSupport.write(files, to: scratch.appending(path: "tree/acme"))
      let before = try RestoreSupport.dump(target)
      let backups = try RestoreSupport.backups(home)
      do {
        _ = try RestoreSupport.restore(directory, into: target, home: home, dryRun: dryRun)
        Issue.record("Restored another workspace's literal document UID")
      } catch let error as ExportError {
        #expect(error.code == .conflict && error.next == ["silta ws ls"] && error.nextBy == .human)
        #expect(error.message.contains("belongs to another workspace"))
        for json in [false, true] {
          let output = OutputRouter.render(.failure(error), mode: OutputMode(json: json))
          if uid == "opaque-ordinary" {
            #expect((output.stdout + output.stderr).contains(uid))
          } else {
            #expect(!(output.stdout + output.stderr).contains(uid))
          }
        }
      }
      #expect(try RestoreSupport.dump(target) == before)
      #expect(try RestoreSupport.backups(home) == backups)
      ExportTreeTests.expectSame(try RestoreService.readTree(directory), files)
      let stored = try target.read {
        try String.fetchOne($0, sql: "SELECT uid FROM doc WHERE id=92")
      }
      #expect(stored.map { Data($0.utf8) } == Data(uid.utf8))
    }
  }

  private static func identities(_ store: DatabaseStore) throws -> [[Data]] {
    let workspace = "(SELECT id FROM workspace WHERE slug='acme')"
    let queries = [
      "SELECT uid,current_rev FROM doc WHERE workspace_id=\(workspace) ORDER BY uid COLLATE BINARY",
      """
      SELECT r.uid,d.uid AS doc,r.rev,t.uid AS source FROM doc_rev r JOIN doc d ON d.id=r.doc_id
      LEFT JOIN task t ON t.id=r.source_task_id WHERE d.workspace_id=\(workspace)
      ORDER BY r.uid COLLATE BINARY
      """,
      """
      SELECT c.uid,r.uid AS owner,c.seq,root.uid AS thread FROM comment c
      JOIN doc_rev r ON r.id=c.doc_rev_id JOIN doc d ON d.id=r.doc_id
      LEFT JOIN comment root ON root.id=c.thread_id WHERE d.workspace_id=\(workspace)
      ORDER BY c.uid COLLATE BINARY
      """,
    ]
    return try store.read { db in
      try queries.map { try Row.fetchAll(db, sql: $0).map { Data($0.description.utf8) } }
    }
  }
}
