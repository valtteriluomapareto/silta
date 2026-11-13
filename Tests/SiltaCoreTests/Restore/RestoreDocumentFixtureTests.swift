import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentFixtureTests {
  @Test func privateCaptureAndRemappingPreserveHistoryAndRetainedState() throws {
    try withScratchDirectory { scratch in
      let source = try RestoreDocumentFixture.source(scratch.appending(path: "source"))
      let before = try RestoreSupport.dump(source)
      let captured = try source.read { try ExportSnapshot.capture($0, workspace: "acme") }
      try RestoreDocumentGraph(tree: captured, documents: captured.documents, slug: "acme").run()
      #expect(
        captured.links.filter { $0.value("to_kind") == "note" }
          .compactMap { $0.value("to_ext").map { Data($0.utf8) } }
          == [Data("caf\u{e9}".utf8), Data("cafe\u{301}".utf8)])
      #expect(
        captured.links.filter { $0.value("to_kind") == "task_plan_rev" }
          .compactMap { $0.value("to_rev") } == ["1", "2"])
      #expect(try RestoreSupport.dump(source) == before)
      let target = try RestoreDocumentRowSupport.make(scratch.appending(path: "target"))
      let retained = try RestoreDocumentFixture.retained(target)
      let tree = try RestoreDocumentGraphFixture.graph().tree
      let expected = try RestoreDocumentRowSupport.replace(
        target, tree: tree, incoming: captured.documents)
      let after = try ExportDocumentSnapshotTests.read(target)
      ExportTreeTests.expectSame(try after.files(), try expected.files())
      #expect(try RestoreDocumentFixture.retained(target) == retained)
    }
  }
}
