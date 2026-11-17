import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocBodyJSONTests {
  @Test func bodyFieldsFollowTheSelectedRenderedWindow() throws {
    try withScratchDirectory { home in
      let store = try accepted(home, body: "Alpha Acme line.\nBeta Acme line.\n")
      let service = DocService(workspace: "acme", store: store)
      let before = try DocVerificationPreparationTests.truth(store)
      let full = try object(service.show("rules"))
      #expect(full["body"] as? String == "Alpha Acme line.\nBeta Acme line.\n")
      #expect(full["title"] as? String == "Rules")
      #expect(full["about"] as? [String] == ["topic:messaging"])
      #expect(full["state"] as? String == "accepted")
      let body = try object(service.show("doc:rules@1", lines: "12-12"))
      #expect(body["body"] as? String == "Alpha Acme line.\n")
      #expect(body["title"] == nil && body["about"] == nil && body["state"] == nil)
      let title = try object(service.show("rules", lines: "2-2"))
      #expect(title["body"] as? String == "" && title["title"] as? String == "Rules")
      #expect(title["about"] == nil && title["state"] == nil)
      let past = try object(service.show("rules", lines: "999-999"))
      #expect(past["body"] as? String == "")
      #expect(past["title"] == nil && past["about"] == nil && past["state"] == nil)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func bodyNeverIncludesClippedSuffixOrSyntheticContinuation() throws {
    try withScratchDirectory { home in
      let lines = (0..<450).map { "Acme line \($0)." }
      let store = try accepted(home, body: lines.joined(separator: "\n") + "\n")
      let service = DocService(workspace: "acme", store: store)
      let full = try object(service.show("rules"))
      #expect(full["body"] as? String == lines.prefix(388).joined(separator: "\n") + "\n")
      #expect(!(full["body"] as? String ?? "").contains("Acme line 388."))
      #expect(!(full["body"] as? String ?? "").contains("lines omitted"))
      let page = try object(service.show("doc:rules@1", lines: "400-403"))
      #expect(page["body"] as? String == lines[388..<392].joined(separator: "\n") + "\n")
      #expect(page["title"] == nil && page["about"] == nil && page["state"] == nil)
    }
  }

  @Test(arguments: ["", "\n", "\r\n"])
  func bodyPreservesUnicodeLegacyNULAndSourceEnding(ending: String) throws {
    try withScratchDirectory { home in
      let expected = "Acme café / cafe\u{301} / 雪\u{0}tail" + ending
      let store = try accepted(home, body: expected)
      let view = try object(DocService(workspace: "acme", store: store).show("rules"))
      #expect((view["body"] as? String).map { Data($0.utf8) } == Data(expected.utf8))
    }
  }

  @Test(arguments: ["title", "why"])
  func crossFieldSecretsCannotReappearInStructuredFields(start: String) throws {
    try withScratchDirectory { home in
      let store = try accepted(
        home, body: "Private Acme material.\n-----END PRIVATE KEY-----\nVisible Acme tail.\n")
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET \(start == "title" ? "title" : "message")=?",
          arguments: ["-----BEGIN PRIVATE KEY-----"])
      }
      let view = try object(DocService(workspace: "acme", store: store).show("rules"))
      let body = view["body"] as? String ?? ""
      #expect(body.contains("Visible Acme tail."))
      #expect(!body.contains("Private Acme material") && !body.contains("PRIVATE KEY"))
      if start == "title" {
        #expect(view["title"] == nil && view["about"] == nil)
      } else {
        #expect(view["title"] as? String == "Rules")
        #expect(view["about"] as? [String] == ["topic:messaging"])
      }
      #expect(view["state"] as? String == "accepted")
    }
  }

  @Test(arguments: [false, true])
  func unknownAndKnownEmptyMetadataStayDifferent(empty: Bool) throws {
    try withScratchDirectory { home in
      let store = try accepted(home, body: "")
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=?,about_refs=?,about_targets=?",
          arguments: [empty ? "" : nil, empty ? "[]" : nil, empty ? "[]" : nil])
        try $0.database.execute(sql: "UPDATE doc SET archived=1")
        try $0.database.execute(sql: "DELETE FROM link WHERE from_kind='doc'")
      }
      let view = try object(DocService(workspace: "acme", store: store).show("doc:rules@1"))
      #expect(view["body"] as? String == "")
      #expect(view["state"] as? String == "accepted")
      if empty {
        #expect(view["title"] as? String == "" && view["about"] as? [String] == [])
      } else {
        #expect(view["title"] == nil && view["about"] == nil)
      }
    }
  }

  @Test(arguments: ["proposed", "rejected", "superseded"])
  func historicalBodyViewsExposeTheirStoredState(state: String) async throws {
    try await withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      let env = try DocTriageServiceTests.environment(home, store)
      let first = try DocTriageServiceTests.propose(
        env, about: "topic:messaging", body: "First Acme knowledge.\n")
      let triage = DocTriageService(
        environment: env, workspace: "acme", approved: "Decide Acme rules")
      if state == "rejected" { _ = try await triage.triage(DocTriage(reject: [first])) }
      if state == "superseded" {
        // Imported history can contain states that current commands do not create.
        try store.write {
          try $0.database.execute(sql: "UPDATE doc_rev SET state='superseded'")
        }
      }
      let view = try object(DocService(workspace: "acme", store: store).show(first))
      #expect(view["body"] as? String == "First Acme knowledge.\n")
      #expect(view["state"] as? String == state)
    }
  }

  @Test func legacyMetadataUsesCompleteMaskedFields() throws {
    try withScratchDirectory { home in
      let store = try accepted(home, body: "Visible Acme body.\n")
      let service = DocService(workspace: "acme", store: store)
      let title = "Acme café\u{0}tail\nsecond title line"
      let refs = ["topic:messaging", "topic:storage"]
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=CAST(? AS TEXT),about_refs=CAST(? AS TEXT)",
          arguments: [Data(title.utf8), try JSONEncoder().encode(refs)])
      }
      let full = try object(service.show("rules"))
      #expect((full["title"] as? String).map { Data($0.utf8) } == Data(title.utf8))
      #expect(full["about"] as? [String] == refs)
      #expect(try object(service.show("rules", lines: "2-2"))["title"] == nil)
      let spanning = [
        "-----BEGIN PRIVATE KEY-----", "Hidden Acme metadata.",
        "-----END PRIVATE KEY-----",
      ]
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET about_refs=CAST(? AS TEXT)",
          arguments: [try JSONEncoder().encode(spanning)])
      }
      let hidden = try object(service.show("rules"))
      #expect(hidden["about"] == nil)
      #expect(hidden["body"] as? String == "Visible Acme body.\n")
      #expect(!(hidden["output"] as? String ?? "").contains("Hidden Acme metadata."))
    }
  }

  @Test func bodyMaskingPrecedesTheSelectedWindow() throws {
    try withScratchDirectory { home in
      let store = try accepted(
        home,
        body: "-----BEGIN PRIVATE KEY-----\nHidden Acme material.\n"
          + "-----END PRIVATE KEY-----\nVisible Acme tail.\n")
      let service = DocService(workspace: "acme", store: store)
      let full = try object(service.show("rules"))
      #expect(full["body"] as? String == "[REDACTED:private_key]\nVisible Acme tail.\n")
      let page = try object(service.show("rules", lines: "13-13"))
      #expect(page["body"] as? String == "Visible Acme tail.\n")
    }
  }

  @Test func nonBodyReadsKeepTheirExistingShape() throws {
    try withScratchDirectory { home in
      let store = try accepted(home, body: "Acme knowledge.")
      _ = try DocProposalServiceTests.service(home, store).propose(
        DocProposalServiceTests.request("pending"), input: { "Pending Acme knowledge." })
      let service = DocService(workspace: "acme", store: store)
      for result in [
        try service.show("rules", diff: true), try service.show("rules", comments: true),
        try service.show("pending"),
      ] {
        #expect(Set(try object(result).keys) == ["ref", "output"])
      }
    }
  }

  private func accepted(_ home: URL, body: String) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: home)
    var draft = DocDraft(slug: "rules", body: body)
    draft.title = "Rules"
    draft.about = ["topic:messaging"]
    _ = try DocStoreTests.accept(draft, in: store, ids: SeededIDGenerator(seed: 83))
    return store
  }

  private func object(_ result: DocReadResult) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
  }
}
