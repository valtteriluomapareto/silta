#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  import SiltaCore
  import SiltaTestSupport
  import Testing

  @Suite(.blockingTestWork) struct AppDocumentTests {
    @Test func listsHistoryProposalsArchivedAndUnknownMetadataWithoutWriting() throws {
      try withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppReaderTests.reader(scratch)
        let probe = try reader.makeChangeProbe()
        let before = try probe.version()
        let list = try reader.documents(workspace: "acme")
        #expect(
          list.entries.contains { $0.ref == "doc:order-contract@2" && $0.state == "accepted" })
        #expect(
          list.entries.contains { $0.ref == "doc:order-contract@3" && $0.state == "proposed" })
        #expect(
          list.entries.contains { $0.ref == "doc:push-categories@1" && $0.state == "proposed" })
        let legacy = try #require(list.entries.first { $0.slug == "legacy-notes" })
        #expect(legacy.title == nil && legacy.kind == nil && legacy.about == nil)
        #expect(!list.entries.contains { $0.archived })
        #expect(
          try reader.documents(workspace: "acme", archived: true).entries.contains { $0.archived })
        #expect(
          try reader.documentVersions("order-contract", workspace: "acme").entries.map(\.revision)
            == [3, 2, 1])
        let comments = try reader.documentComments("doc:order-contract@2", workspace: "acme")
        #expect(
          comments.entries.count == 1 && comments.entries.first?.body.contains("Confirmed") == true)
        #expect(try probe.version() == before)
      }
    }

    @Test func bodyPagingPreservesEveryLineAndCoreJSONKeepsItsShape() throws {
      try withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppReaderTests.reader(scratch)
        let first = try reader.document("doc:operations@1", workspace: "acme")
        let next = try #require(first.nextLine)
        let second = try reader.document("doc:operations@1", workspace: "acme", fromLine: next)
        let body = (first.body ?? "") + (second.body ?? "")
        let steps = body.components(separatedBy: "\n").filter { $0.hasPrefix("Operational step ") }
        #expect(steps.count == 500 && Set(steps).count == 500 && second.nextLine == nil)
        #expect(body.contains("Operational step 500."))
        let core = DocService(workspace: "acme", store: reader.environment.db)
        let json =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(core.list()))
          as? [String: Any]
        let entry = try #require((json?["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["ref", "state", "output"])
        let show =
          try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(core.show("doc:operations@1"))) as? [String: Any]
        #expect(show?["metadata"] == nil && show?["rendered"] == nil && show?["nextLine"] == nil)
      }
    }
  }
#endif
