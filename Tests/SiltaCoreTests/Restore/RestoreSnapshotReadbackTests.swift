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
      after.format = "4"
      after.schema = "v8"
      try store.write(rollingBack: true) { tx in
        let writer = RestoreWriter(tx: tx, tree: incoming, slug: "acme")
        try writer.check(after, revisionAllocations: [])
      }
    }
  }

  @Test func readbackAllowsOnlyExplicitRestoreNormalizations() throws {
    try withScratchDirectory { home in
      let store = try ExportFixture.make(home)
      let graph = try RestoreDocumentGraphFixture.graph()
      var after = graph
      after.schema = "v8"
      after.documents.legacyCommentSequences = nil
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
        let writer = RestoreWriter(tx: tx, tree: graph, slug: "acme")
        try writer.check(after, revisionAllocations: floors)
      }
      for key in ["unknown-title", "triaged_by", "app_shas", "body_md", "about_targets"] {
        var damaged = after
        let index = key == "app_shas" ? 5 : (key == "unknown-title" ? 0 : 1)
        RestoreDocumentGraphFixture.record(
          &damaged.documents, index, key == "unknown-title" ? "title" : key,
          key == "app_shas" ? "[]" : "Invented value")
        try store.write(rollingBack: true) { tx in
          let writer = RestoreWriter(tx: tx, tree: graph, slug: "acme")
          #expect(throws: ExportError.self) {
            try writer.check(damaged, revisionAllocations: floors)
          }
        }
      }
      try store.write(rollingBack: true) { tx in
        let writer = RestoreWriter(tx: tx, tree: graph, slug: "acme")
        #expect(throws: ExportError.self) {
          try writer.check(after, revisionAllocations: graph.documents.revisionAllocations)
        }
      }
    }
  }
}
