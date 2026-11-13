import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentGraphTests {
  typealias Change = @Sendable (inout ExportSnapshot, inout ExportDocumentSnapshot) -> Void

  struct Damage: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let apply: Change
  }

  static let damages: [Damage] = [
    .init(testDescription: "duplicate document UID") { _, d in
      RestoreDocumentGraphFixture.otherDocument(&d)
      d.documents[1].row = d.documents[1].row.replacing(
        "uid", with: ExportDocumentTests.uid("001"), keys: ExportFormat.docKeys)
    },
    .init(testDescription: "cross document verification") { _, d in
      RestoreDocumentGraphFixture.otherDocument(&d)
      RestoreDocumentGraphFixture.record(&d, 5, "doc_rev", "other-revision")
    },
    .init(testDescription: "missing source task") { _, d in
      RestoreDocumentGraphFixture.record(&d, 1, "source_task", "gone")
    },
    .init(testDescription: "missing base") { _, d in
      RestoreDocumentGraphFixture.record(&d, 1, "base_rev", "99")
    },
    .init(testDescription: "earlier missing owned base") { _, d in
      RestoreDocumentGraphFixture.record(&d, 3, "base_rev", "4")
    },
    .init(testDescription: "self base") { _, d in
      RestoreDocumentGraphFixture.record(&d, 1, "base_rev", "2")
    },
    .init(testDescription: "missing current") { _, d in
      RestoreDocumentGraphFixture.document(&d, "current_rev", "99")
    },
    .init(testDescription: "rejected current") { _, d in
      RestoreDocumentGraphFixture.document(&d, "current_rev", "5")
    },
    .init(testDescription: "orphan accepted history") { _, d in
      RestoreDocumentGraphFixture.document(&d, "current_rev", nil)
    },
    .init(testDescription: "half audit") { _, d in
      RestoreDocumentGraphFixture.record(&d, 1, "triaged_by", nil)
    },
    .init(testDescription: "verification owner") { _, d in
      RestoreDocumentGraphFixture.record(&d, 5, "doc_rev", "gone")
    },
    .init(testDescription: "comment owner") { _, d in
      RestoreDocumentGraphFixture.record(&d, 6, "doc_rev", "gone")
    },
    .init(testDescription: "cross revision thread") { _, d in
      RestoreDocumentGraphFixture.record(&d, 6, "doc_rev", ExportDocumentTests.uid("053"))
      d.commentSequences[2] = d.commentSequences[2].replacing(
        "next", with: "2", keys: ["doc_rev", "next"])
    },
    .init(testDescription: "missing thread") { _, d in
      RestoreDocumentGraphFixture.record(&d, 7, "thread", "gone")
    },
    .init(testDescription: "thread cycle") { _, d in
      RestoreDocumentGraphFixture.record(&d, 6, "thread", ExportDocumentTests.uid("041"))
    },
    .init(testDescription: "duplicate task/doc comment UID") { t, d in
      let uid = t.tasks[0].records.first { $0.value("table") == "comment" }?.value("uid")
      let keys = ExportFormat.docRecords[2].keys
      d.documents[0].records.append(
        d.documents[0].records[6]
          .replacing("uid", with: uid, keys: keys).replacing("seq", with: "8", keys: keys))
    },
    .init(testDescription: "no current about") { t, d in
      RestoreDocumentGraphFixture.document(&d, "archived", "0")
      t.links.removeAll { $0.value("from_kind") == "doc" && $0.value("rel") == "about" }
    },
    .init(testDescription: "dangling about") { t, _ in
      RestoreDocumentGraphFixture.link(&t, 3, "to", "gone")
    },
    .init(testDescription: "external about") { t, _ in
      RestoreDocumentGraphFixture.link(&t, 3, "to_kind", "code")
      RestoreDocumentGraphFixture.link(&t, 3, "to", nil)
      RestoreDocumentGraphFixture.link(&t, 3, "to_ext", "doc:Sources/Rules.swift")
    },
    .init(testDescription: "unknown link kind") { t, _ in
      RestoreDocumentGraphFixture.link(&t, 0, "to_kind", "future")
    },
    .init(testDescription: "unsafe code path") { t, _ in
      RestoreDocumentGraphFixture.link(&t, 8, "to_ext", "doc:../escape")
    },
    .init(testDescription: "both target forms") { t, _ in
      RestoreDocumentGraphFixture.link(&t, 0, "to_ext", "ambiguous")
    },
    .init(testDescription: "duplicate link identity") { t, _ in
      t.links.append(t.links[0].replacing("uid", with: "another", keys: ExportFormat.linkKeys))
    },
    .init(testDescription: "empty anchor aliases absent anchor") { t, _ in
      let duplicate = t.links[0].replacing("uid", with: "another", keys: ExportFormat.linkKeys)
        .replacing("anchor", with: "", keys: ExportFormat.linkKeys)
      t.links.append(duplicate)
    },
    .init(testDescription: "invalid historical about array") { _, d in
      RestoreDocumentGraphFixture.record(&d, 1, "about_refs", "{}")
    },
    .init(testDescription: "invalid historical evidence array") { _, d in
      RestoreDocumentGraphFixture.record(&d, 5, "app_shas", "not JSON")
    },
  ]

  @Test func literalHistoryAndLegacyIdentitiesAreValidWithoutRewriting() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.document(&graph.documents, "archived", "0")
    let before = graph
    try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
    #expect(graph.tree == before.tree && graph.documents == before.documents)
    #expect(graph.documents.documents[0].records[0].value("about_refs") == nil)
    #expect(
      graph.documents.documents[0].records[1].value("about_refs") == ExportDocumentTests.about)
  }

  @Test func legacyTitlesAndKindsDoNotAcquireNewWriteRestrictions() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.otherDocument(&graph.documents)
    let before = graph.documents
    try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
    #expect(graph.documents == before)
  }

  @Test func storedCodePointersCanOutliveTheirMapApp() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.link(&graph.tree, 8, "to_ext", "retired:Sources/Old.swift#L1-2")
    try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
    #expect(graph.tree.links[8].value("to_ext") == "retired:Sources/Old.swift#L1-2")
  }

  @Test(arguments: damages)
  func malformedGraphsRefuse(_ damage: Damage) throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    damage.apply(&graph.tree, &graph.documents)
    #expect(throws: ExportError.self) {
      try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
    }
  }

  @Test func halfAuditHasScopedUnchangedTreeRecovery() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.record(&graph.documents, 1, "triaged_by", nil)
    do {
      try RestoreDocumentGraph(tree: graph.tree, documents: graph.documents, slug: "acme").run()
      Issue.record("Accepted half of a triage audit pair")
    } catch let error as ExportError {
      #expect(error.code == .invalid && error.nextBy == .human)
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      Golden.forTests().check(text.stderr + json.stdout, "restore-doc-graph-error.txt")
    }
  }

  @Test func typedLinksMapEveryOwnerToStableUIDsWithoutWriting() throws {
    try withScratchDirectory { home in
      let store = try RestoreDocumentGraphFixture.source(home)
      let before = try RestoreSupport.dump(store)
      let links = try store.read { try ExportLinks.read($0, workspace: 17) }
      let expected = try RestoreDocumentGraphFixture.links()
      #expect(links == expected)
      Golden.forTests().check(ExportFormat.jsonl(links), "export/typed-doc-links/links.jsonl")
      #expect(try RestoreSupport.dump(store) == before)
      #expect(throws: ExportError.unsupported("docs")) {
        try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      }
    }
  }
}
