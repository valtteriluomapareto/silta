import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreGraphIdentityTests {
  @Test(arguments: ["title", "kind"])
  func knownCurrentMetadataMustMatchProjection(_ key: String) throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.document(&graph.documents, key, "Different projection")
    let files = try graph.documents.files()
    graph.documents = try ExportDocumentSnapshot.parse(files, workspace: "acme")
    do {
      try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
      Issue.record("Accepted inconsistent current document metadata")
    } catch let error as ExportError {
      #expect(
        error
          == .invalidTree(
            reason: "current document metadata differs from its accepted revision",
            workspace: "acme"))
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      Golden.forTests().check(text.stderr + json.stdout, "restore-doc-current-metadata.txt")
    }
    RestoreDocumentGraphFixture.record(&graph.documents, 1, key, nil)
    try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
    let legacy = key == "title" ? "Legacy\n" + String(repeating: "x", count: 121) : "design"
    RestoreDocumentGraphFixture.document(&graph.documents, key, legacy)
    RestoreDocumentGraphFixture.record(&graph.documents, 1, key, legacy)
    try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
  }

  @Test func byteDistinctLinksFromTheShippedWriterRemainDistinct() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, start: true, directory: home)
      let targets = ["caf\u{e9}", "cafe\u{301}"]
      #expect(targets[0] == targets[1])
      #expect(Data(targets[0].utf8) != Data(targets[1].utf8))
      for target in targets { _ = try service.link("AC-1", target: "note:" + target) }
      let store = service.environment.db
      let before = try RestoreSupport.dump(store)
      let tree = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      let captured = tree.links.filter { $0.value("to_kind") == "note" }
      let raw = try store.read {
        try String.fetchAll($0, sql: "SELECT to_ext FROM link WHERE to_kind='note' ORDER BY id")
      }
      #expect(raw.map { Data($0.utf8) } == targets.map { Data($0.utf8) })
      #expect(Set(captured.compactMap { $0.value("to_ext").map { Data($0.utf8) } }).count == 2)
      let documents = ExportDocumentSnapshot(
        documents: [], revisionAllocations: [], commentSequences: [])
      try RestoreDocumentGraph(tree: tree, documents: documents, slug: "acme").run()
      #expect(try RestoreSupport.dump(store) == before)
    }
  }
}
