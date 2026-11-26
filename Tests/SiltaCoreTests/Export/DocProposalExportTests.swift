import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalExportTests {
  @Test func targetSnapshotsAreVersionedAndRoundTripWithoutCurrentTargets() throws {
    do {
      try withScratchDirectory { home in
        let store = try AcmeDocAttachments.make(in: home)
        _ = try DocProposalServiceTests.service(home, store).propose(
          DocProposalServiceTests.request(), input: { "Shared body" })
        let columns = try store.read { try $0.columns(in: "doc_rev").map(\.name) }
        #expect(columns.contains("about_targets"))
        #expect(
          try store.read {
            try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
          } == DatabaseStore.writerVersion)
        let files = try ExportTreeTests.render(store)
        #expect(try ExportVersionTests.version(files) == "4")
        let snapshot = try ExportTree.parse(files)
        let revision = try #require(snapshot.documents.documents.first?.records.first)
        #expect(revision.value("about_targets") != nil)
        if revision.value("about_targets") != nil {
          var historical = snapshot
          historical.sections = historical.sections.map {
            var section = $0
            if section.name == "services" || section.name == "edges" { section.rows = [] }
            return section
          }
          let output = try historical.files()
          let directory = try RestoreSupport.write(output, to: home.appending(path: "export"))
          let destination = ExportFixture.store(home.appending(path: "destination"))
          try destination.initialize()
          _ = try RestoreSupport.restore(
            directory, into: destination, home: home.appending(path: "destination"))
          let restored = try ExportTree.parse(ExportTreeTests.render(destination))
          #expect(restored.documents == historical.documents)
        }
      }
    }
  }

  @Test(arguments: [
    "[]", "[{}]", "null", #"[{"kind":"unknown","uid":"id"}]"#,
    #"[{"kind":"service","uid":""}]"#, #"[{"kind":"service","uid":"\u212a"}]"#,
    #"[{"kind":"service","uid":"id\u0000suffix"}]"#,
    #"[{"kind":"app","uid":"historical"}]"#,
    #"[{"kind":"service","uid":1}]"#,
    #"[{"kind":"service","uid":"id"},{"kind":"service","uid":"other"}]"#,
    #"[{"kind":"service","uid":"id"},{"kind":"service","uid":"id"}]"#,
  ])
  func malformedKnownTargetsRefuse(snapshot: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      _ = try DocProposalServiceTests.service(home, store).propose(
        DocProposalServiceTests.request(), input: { "Body" })
      var tree = try ExportTree.parse(ExportTreeTests.render(store))
      tree.format = "4"
      var record = try #require(tree.documents.documents.first?.records.first)
      if snapshot.contains(#""kind":"unknown""#) {
        record = record.replacing(
          "about_refs", with: #"["unknown:historical"]"#, keys: record.fields.map(\.key))
      }
      if snapshot == #"[{"kind":"service","uid":"id"},{"kind":"service","uid":"id"}]"# {
        record = record.replacing(
          "about_refs", with: #"["service:push","service:push"]"#, keys: record.fields.map(\.key))
      }
      let keys =
        record.fields.map(\.key)
        + (record.value("about_targets") == nil ? ["about_targets"] : [])
      tree.documents.documents[0].records[0] = record.replacing(
        "about_targets", with: snapshot, keys: keys)
      #expect(throws: ExportError.self) {
        let parsed = try ExportTree.parse(tree.files())
        try RestoreDocumentGraph(tree: parsed, slug: "acme").run()
      }
    }
  }

  @Test func olderFormatCannotAcquireTargetSnapshots() throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      _ = try DocProposalServiceTests.service(home, store).propose(
        DocProposalServiceTests.request(), input: { "Body" })
      var files = try ExportTreeTests.render(store)
      let data = try #require(files["manifest.json"])
      let manifest = try #require(String(data: data, encoding: .utf8))
      files["manifest.json"] = Data(
        manifest.replacingOccurrences(of: #""format": "4""#, with: #""format": "3""#).utf8)
      #expect(throws: ExportError.self) { try ExportTree.parse(files) }
    }
  }

  @Test func frozenFormatThreeKeepsItsExactBytes() throws {
    var files = try ExportTreeTests.golden("acme")
    let path = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Golden/export-v3-manifest.json")
    files["manifest.json"] = try Data(contentsOf: path)
    #expect(try ExportVersionTests.version(files) == "3")
    ExportTreeTests.expectSame(try ExportTree.parse(files).files(), files)
  }
}
