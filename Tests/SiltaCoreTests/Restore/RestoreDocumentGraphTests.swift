import Foundation
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct RestoreDocumentGraphTests {
  typealias Change = @Sendable (inout ExportSnapshot) -> Void

  struct Damage: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let apply: Change
  }

  static let damages: [Damage] = [
    .init(testDescription: "duplicate document UID") { t in
      RestoreDocumentGraphFixture.otherDocument(&t.documents)
      t.documents.documents[1].row = t.documents.documents[1].row.replacing(
        "uid", with: ExportDocumentTests.uid("001"), keys: ExportFormat.docKeys)
    },
    .init(testDescription: "cross document verification") { t in
      RestoreDocumentGraphFixture.otherDocument(&t.documents)
      RestoreDocumentGraphFixture.record(&t.documents, 5, "doc_rev", "other-revision")
    },
    .init(testDescription: "missing source task") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 1, "source_task", "gone")
    },
    .init(testDescription: "missing base") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 1, "base_rev", "99")
    },
    .init(testDescription: "earlier missing owned base") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 3, "base_rev", "4")
    },
    .init(testDescription: "self base") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 1, "base_rev", "2")
    },
    .init(testDescription: "missing current") { t in
      RestoreDocumentGraphFixture.document(&t.documents, "current_rev", "99")
    },
    .init(testDescription: "rejected current") { t in
      RestoreDocumentGraphFixture.document(&t.documents, "current_rev", "5")
    },
    .init(testDescription: "orphan accepted history") { t in
      RestoreDocumentGraphFixture.document(&t.documents, "current_rev", nil)
    },
    .init(testDescription: "half audit") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 1, "triaged_by", nil)
    },
    .init(testDescription: "verification owner") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 5, "doc_rev", "gone")
    },
    .init(testDescription: "comment owner") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 6, "doc_rev", "gone")
    },
    .init(testDescription: "cross revision thread") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 6, "doc_rev", ExportDocumentTests.uid("053"))

    },
    .init(testDescription: "missing thread") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 7, "thread", "gone")
    },
    .init(testDescription: "thread cycle") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 6, "thread", ExportDocumentTests.uid("041"))
    },
    .init(testDescription: "duplicate task/doc comment UID") { t in
      let uid = t.tasks[0].records.first { $0.value("table") == "comment" }?.value("uid")
      let keys = ExportFormat.docRecords[2].keys
      t.documents.documents[0].records.append(
        t.documents.documents[0].records[6]
          .replacing("uid", with: uid, keys: keys).replacing("seq", with: "8", keys: keys))
    },
    .init(testDescription: "no current about") { t in
      RestoreDocumentGraphFixture.document(&t.documents, "archived", "0")
      t.links.removeAll { $0.value("from_kind") == "doc" && $0.value("rel") == "about" }
    },
    .init(testDescription: "dangling about") { t in
      RestoreDocumentGraphFixture.link(&t, 3, "to", "gone")
    },
    .init(testDescription: "external about") { t in
      RestoreDocumentGraphFixture.link(&t, 3, "to_kind", "code")
      RestoreDocumentGraphFixture.link(&t, 3, "to", nil)
      RestoreDocumentGraphFixture.link(&t, 3, "to_ext", "doc:Sources/Rules.swift")
    },
    .init(testDescription: "unknown link kind") { t in
      RestoreDocumentGraphFixture.link(&t, 0, "to_kind", "future")
    },
    .init(testDescription: "unsafe code path") { t in
      RestoreDocumentGraphFixture.link(&t, 8, "to_ext", "doc:../escape")
    },
    .init(testDescription: "both target forms") { t in
      RestoreDocumentGraphFixture.link(&t, 0, "to_ext", "ambiguous")
    },
    .init(testDescription: "duplicate link identity") { t in
      t.links.append(t.links[0].replacing("uid", with: "another", keys: ExportFormat.linkKeys))
    },
    .init(testDescription: "empty anchor aliases absent anchor") { t in
      let duplicate = t.links[0].replacing("uid", with: "another", keys: ExportFormat.linkKeys)
        .replacing("anchor", with: "", keys: ExportFormat.linkKeys)
      t.links.append(duplicate)
    },
    .init(testDescription: "invalid historical about array") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 1, "about_refs", "{}")
    },
    .init(testDescription: "invalid historical evidence array") { t in
      RestoreDocumentGraphFixture.record(&t.documents, 5, "app_shas", "not JSON")
    },
  ]

  @Test func literalHistoryAndLegacyIdentitiesAreValidWithoutRewriting() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.document(&graph.documents, "archived", "0")
    let before = graph
    try RestoreDocumentGraph(tree: graph, slug: "acme").run()
    #expect(graph == before)
    #expect(graph.documents.documents[0].records[0].value("about_refs") == nil)
    #expect(
      graph.documents.documents[0].records[1].value("about_refs") == ExportDocumentTests.about)
  }

  @Test func legacyTitlesAndKindsDoNotAcquireNewWriteRestrictions() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.otherDocument(&graph.documents)
    let before = graph.documents
    try RestoreDocumentGraph(tree: graph, slug: "acme").run()
    #expect(graph.documents == before)
  }

  @Test func storedCodePointersCanOutliveTheirMapApp() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.link(&graph, 8, "to_ext", "retired:Sources/Old.swift#L1-2")
    try RestoreDocumentGraph(tree: graph, slug: "acme").run()
    #expect(graph.links[8].value("to_ext") == "retired:Sources/Old.swift#L1-2")
  }

  @Test(arguments: damages)
  func malformedGraphsRefuse(_ damage: Damage) throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    damage.apply(&graph)
    #expect(throws: ExportError.self) {
      try RestoreDocumentGraph(tree: graph, slug: "acme").run()
    }
  }

  @Test func halfAuditHasScopedUnchangedTreeRecovery() throws {
    var graph = try RestoreDocumentGraphFixture.graph()
    RestoreDocumentGraphFixture.record(&graph.documents, 1, "triaged_by", nil)
    do {
      try RestoreDocumentGraph(tree: graph, slug: "acme").run()
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
      #expect(try store.read { try ExportSnapshot.read($0, workspace: "acme").links } == links)
    }
  }
}
