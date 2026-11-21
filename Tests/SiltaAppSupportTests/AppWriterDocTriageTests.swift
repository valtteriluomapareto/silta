#if DEBUG
  import Foundation
  @testable import SiltaAppSupport
  @testable import SiltaCore
  import SiltaTestSupport
  import Testing

  /// Accepting and rejecting document revisions through the app's writer.
  @Suite(.blockingTestWork)
  struct AppWriterDocTriageTests {
    static func state(_ reader: AppReader, _ ref: String) throws -> String? {
      let slug = String(ref.dropFirst("doc:".count).prefix { $0 != "@" })
      return try reader.documentVersions("doc:" + slug, workspace: "acme").entries
        .first { $0.ref == ref }?.state
    }

    @Test func rejectingARevisionRecordsTheHumanAndLogs() async throws {
      try await withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppWriterTests.reader(scratch)
        let proposals = try reader.snapshot(workspace: "acme").work.items
          .filter { $0.kind == "doc_proposal" }.flatMap(\.refs)
        let ref = try #require(proposals.first)
        try await AppWriter(reader: reader).send(
          .triageDocuments(accept: [], reject: [ref]), workspace: "acme")
        #expect(try Self.state(reader, ref) == "rejected")
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2026-11-16.jsonl"), encoding: .utf8)
        #expect(log.contains("\"command\":\"app doc-triage\""))
      }
    }

    @Test func acceptingANewDocumentMakesItCurrent() async throws {
      try await withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppWriterTests.reader(scratch)
        try await AppWriter(reader: reader).send(
          .triageDocuments(accept: ["doc:push-categories@1"], reject: []), workspace: "acme")
        #expect(try Self.state(reader, "doc:push-categories@1") == "accepted")
      }
    }

    @Test func aRevisionDecidedElsewhereFailsTheWholeBatch() async throws {
      try await withScratchDirectory { scratch in
        try AppDocsFixture.seed(home: scratch.appending(path: "silta-home"))
        let reader = try AppWriterTests.reader(scratch)
        try await AppWriter(reader: reader).send(
          .triageDocuments(accept: [], reject: ["doc:order-contract@3"]), workspace: "acme")
        var failure: AppReadError?
        do {
          try await AppWriter(reader: reader).send(
            .triageDocuments(
              accept: [], reject: ["doc:order-contract@3", "doc:push-categories@1"]),
            workspace: "acme")
        } catch let error as AppReadError {
          failure = error
        }
        #expect(failure?.code == .invalid)
        #expect(try Self.state(reader, "doc:push-categories@1") == "proposed")
      }
    }
  }
#endif
