import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension RestoreServiceTests {
  /// Seeded workspaces of every shape round-trip byte for byte, into a fresh home and
  /// in place. A failure names its seed.
  @Test(arguments: Array(UInt64(0)..<6))
  func generatedWorkspacesRoundTrip(seed: UInt64) throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "a")
      let store = try ExportFixture.make(home)
      var generator = RestoreGenerator(seed: seed)
      try DatabaseQueue(path: store.path).write { try generator.insert($0) }
      let exported = try ExportTreeTests.render(store)
      let snapshot = try ExportTree.parse(exported)
      Self.expectGeneratedDocuments(snapshot)
      let tree = try RestoreSupport.write(exported, to: scratch.appending(path: "tree/acme"))
      let fresh = ExportFixture.store(scratch.appending(path: "b"))
      try fresh.initialize()
      _ = try RestoreSupport.restore(tree, into: fresh, home: scratch.appending(path: "b"))
      ExportTreeTests.expectSame(try ExportTreeTests.render(fresh), exported)
      _ = try RestoreSupport.restore(tree, into: store, home: home)
      ExportTreeTests.expectSame(try ExportTreeTests.render(store), exported)
    }
  }

  private static func expectArchivedDiscussion(
    _ doc: ExportDocument?, allocations: [ExportRow]
  ) {
    #expect(doc?.row.value("archived") == "1" && doc?.row.value("current_rev") == "1")
    let revisions = doc?.records.filter { $0.value("table") == "doc_rev" } ?? []
    #expect(revisions.count >= 2)
    #expect(revisions.first?.value("triaged_at") == "2023-11-15T00:07:00.000Z")
    #expect(revisions.first?.value("triaged_by") == "human:acme")
    let proposed = revisions.last
    #expect(proposed?.value("state") == "proposed" && proposed?.value("base_rev") == "1")
    #expect(proposed?.value("about_refs") == #"["app:portal"]"#)
    #expect(
      proposed?.value("about_targets") == #"[{"kind":"app","uid":"01HZAPP0000000000000000009"}]"#)
    let comments = doc?.records.filter { $0.value("table") == "comment" } ?? []
    #expect(comments.map { $0.value("seq") } == ["1", "3"])
    #expect(comments.allSatisfy { $0.value("doc_rev") == proposed?.value("uid") })
    #expect(comments.last?.value("thread") == comments.first?.value("uid"))
    let allocation = allocations.first { $0.value("slug") == "generated-archived" }
    let next = allocation?.value("next").flatMap(Int.init) ?? 0
    #expect(next > revisions.count + 1)
  }

  private static func expectGeneratedDocuments(_ snapshot: ExportSnapshot) {
    let documents = snapshot.documents.documents
    let active = documents.first { $0.slug == "generated-active" }
    let pending = documents.first { $0.slug == "generated-pending" }
    let archived = documents.first { $0.slug == "generated-archived" }
    let revisions = active?.records.filter { $0.value("table") == "doc_rev" } ?? []
    #expect(active?.row.value("archived") == "0" && active?.row.value("current_rev") == "1")
    #expect(pending?.row.value("archived") == "0" && pending?.row.value("current_rev") == nil)
    #expect(pending?.records.map { $0.value("state") } == ["proposed"])
    expectArchivedDiscussion(archived, allocations: snapshot.documents.revisionAllocations)
    #expect(
      revisions.map { $0.value("state") } == ["accepted", "proposed", "rejected", "superseded"])
    let verification = active?.records.first { $0.value("table") == "doc_verification" }
    #expect(verification != nil && verification?.value("doc_rev") == revisions.first?.value("uid"))
    let attachments = snapshot.links.filter {
      $0.value("from_kind") == "doc" && $0.value("from") == active?.row.value("uid")
        && $0.value("rel") == "about"
    }
    #expect(attachments.map { $0.value("to_kind") } == ["app"])
    #expect(attachments.map { $0.value("to") } == ["01HZAPP0000000000000000009"])
  }
}
