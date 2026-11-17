#if DEBUG
  import Foundation
  import GRDB
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

    @Test func revisionAttributionIsRecordedMaskedAndReadOnly() throws {
      try withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppReaderTests.reader(scratch)
        try reader.environment.db.write {
          try $0.database.execute(
            sql: "UPDATE doc_rev SET message='Password=private123'")
        }
        let probe = try reader.makeChangeProbe()
        let before = try probe.version()
        let list = try reader.documents(workspace: "acme").entries
        let history = try reader.documentVersions("order-contract", workspace: "acme").entries
        let body = try #require(
          try reader.document("doc:order-contract@3", workspace: "acme").document)
        let diff = try #require(
          try reader.document("doc:order-contract@3", workspace: "acme", view: .changes).document)
        for doc in list + history + [body, diff] {
          #expect(doc.actor != nil && doc.createdAt != nil)
          #expect(doc.message?.contains("private123") == false)
          #expect(doc.message?.contains("[REDACTED:password]") == true)
          if doc.ref == "doc:order-contract@3" {
            #expect(doc.actor == "agent:codex:fixture" && doc.sourceTask == "AC-9")
          }
        }
        #expect(try probe.version() == before)
      }
    }

    @Test func encodedAttachmentSecretsAreMaskedInEveryTypedRead() throws {
      try withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppReaderTests.reader(scratch)
        let refs = [
          "edge:api/service:push/Password%3Dprivate123", "edge:api/service:push/HTTP%20API",
        ]
        let encoded = try #require(String(data: try JSONEncoder().encode(refs), encoding: .utf8))
        try reader.environment.db.write {
          try $0.database.execute(sql: "UPDATE doc_rev SET about_refs=?", arguments: [encoded])
        }
        let list = try reader.documents(workspace: "acme").entries
        let history = try reader.documentVersions("order-contract", workspace: "acme").entries
        let body = try #require(
          try reader.document("doc:order-contract@2", workspace: "acme").document)
        let diff = try #require(
          try reader.document("doc:order-contract@3", workspace: "acme", view: .changes).document)
        for entry in list + history + [body, diff] {
          let about = try #require(entry.about)
          #expect(about.contains(refs[1]))
          #expect(!about.joined().contains("private123"))
          #expect(about.joined().contains("[REDACTED:password]"))
        }
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
        let start = try #require(first.lines)
        let end = try #require(second.lines)
        #expect(start.first == 1 && start.total == 502 && start.last < start.total)
        #expect(end.first == start.last + 1 && end.last == 502 && end.total == 502)
        let empty = try reader.document("doc:operations@1", workspace: "acme", fromLine: 9999)
        #expect(empty.lines?.first == 0 && empty.lines?.last == 0 && empty.lines?.total == 502)
        let core = DocService(workspace: "acme", store: reader.environment.db)
        let json =
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(core.list()))
          as? [String: Any]
        let entry = try #require((json?["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["ref", "state", "output"])
        let show =
          try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(core.show("doc:operations@1"))) as? [String: Any]
        #expect(
          show?["metadata"] == nil && show?["rendered"] == nil && show?["nextLine"] == nil
            && show?["lines"] == nil)
      }
    }
  }
#endif
