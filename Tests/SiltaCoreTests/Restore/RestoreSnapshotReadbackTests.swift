import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreSnapshotReadbackTests {
  @Test func genuineOldFormatNormalizesOnlyTheCurrentEnvelope() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let incoming = try ExportTree.parse(ExportVersionTests.frozen())
      var after = incoming
      after.format = "2"
      after.schema = "v7"
      try store.write(rollingBack: true) { tx in
        let writer = RestoreWriter(tx: tx, tree: incoming, slug: "acme")
        try writer.check(after, revisionAllocations: [])
      }
    }
  }

  @Test func readbackAllowsOnlyExplicitRestoreNormalizations() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      var graph = try RestoreDocumentGraphFixture.graph()
      graph.tree.documents = graph.documents
      var after = graph.tree
      after.schema = "v7"
      after.workspace = after.workspace.replacing(
        "next_task_seq", with: "900", keys: ExportFormat.workspaceKeys)
      after.approvals.append(
        ExportDocumentTests.row([
          ("uid", "retained-approval"), ("actor", "human:acme"),
          ("command", "silta ws edit"), ("words", "Approved"), ("created_at", ""),
        ]))
      var floors = after.documents.revisionAllocations
      floors[1] = floors[1].replacing("next", with: "151", keys: ["slug", "next"])
      floors.append(ExportDocumentTests.row([("slug", "absent-name"), ("next", "333")]))
      after.documents.revisionAllocations = floors
      try store.write(rollingBack: true) { tx in
        let writer = RestoreWriter(tx: tx, tree: graph.tree, slug: "acme")
        try writer.check(after, revisionAllocations: floors)
      }
      for key in ["comment-counter", "unknown-title", "triaged_by", "app_shas", "body_md"] {
        var damaged = after
        if key == "comment-counter" {
          damaged.documents.commentSequences[1] = damaged.documents.commentSequences[1].replacing(
            "next", with: "99", keys: ["doc_rev", "next"])
        } else {
          let index = key == "app_shas" ? 5 : (key == "unknown-title" ? 0 : 1)
          RestoreDocumentGraphFixture.record(
            &damaged.documents, index, key == "unknown-title" ? "title" : key,
            key == "app_shas" ? "[]" : "Invented value")
        }
        try store.write(rollingBack: true) { tx in
          let writer = RestoreWriter(tx: tx, tree: graph.tree, slug: "acme")
          #expect(throws: ExportError.self) {
            try writer.check(damaged, revisionAllocations: floors)
          }
        }
      }
      try store.write(rollingBack: true) { tx in
        let writer = RestoreWriter(tx: tx, tree: graph.tree, slug: "acme")
        #expect(throws: ExportError.self) {
          try writer.check(after, revisionAllocations: graph.documents.revisionAllocations)
        }
      }
    }
  }
}
