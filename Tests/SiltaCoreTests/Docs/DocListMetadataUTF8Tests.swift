import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocListMetadataUTF8Tests {
  @Test(arguments: ["title", "kind", "about_refs"])
  func completeMetadataIsMaskedBeforeListPreview(field: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let value = "-----BEGIN PRIVATE KEY-----\nprivate-acme\u{0}\n-----END PRIVATE KEY-----"
      let bytes = field == "about_refs" ? try JSONEncoder().encode([value]) : Data(value.utf8)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET \(field)=CAST(? AS TEXT)", arguments: [bytes])
      }
      #expect(try stored(field, in: store) == bytes)
      let before = try DocVerificationPreparationTests.truth(store)
      for flags in [[], ["--about", "app:api"], ["--archived", "--offset", "0", "--limit", "1"]] {
        for json in [false, true] {
          let result = try SiltaBinary.run(
            ["--ws", "acme", "doc", "ls"] + flags + (json ? ["--json"] : []), in: scratch)
          #expect(result.termination == .exit(0) && result.stderr.isEmpty)
          #expect(!result.stdout.contains("private-acme"))
          #expect(result.stdout.contains("[REDACTED:private_key]"))
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(try stored(field, in: store) == bytes)
    }
  }

  @Test(arguments: ["title", "kind", "about_refs"])
  func invalidStoredMetadataRefusesWithoutPartialOutput(field: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let invalid = Data([0x41, 0xFF, 0x42])
      let bytes = field == "about_refs" ? Data("[\"".utf8) + invalid + Data("\"]".utf8) : invalid
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET \(field)=CAST(? AS TEXT)", arguments: [bytes])
      }
      #expect(try stored(field, in: store) == bytes)
      let before = try DocVerificationPreparationTests.truth(store)
      #expect(throws: StorageError.corrupt) {
        _ = try DocService(workspace: "acme", store: store).list()
      }
      let result = try SiltaBinary.run(["--ws", "acme", "doc", "ls", "--json"], in: scratch)
      #expect(result.termination == .exit(9) && result.stderr.isEmpty)
      let envelope = try #require(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let error = try #require(envelope["error"] as? [String: Any])
      #expect(error["code"] as? String == "env" && envelope["data"] == nil)
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(try stored(field, in: store) == bytes)
    }
  }

  @Test func nullSnapshotsRemainUnknownWithoutProjectionFallback() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev WHERE title IS NULL")
        } == 1)
      let before = try DocVerificationPreparationTests.truth(store)
      let result = try SiltaBinary.run(["--ws", "acme", "doc", "ls", "--json"], in: scratch)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      #expect(result.stdout.contains("(unknown)") && !result.stdout.contains("Private Acme title"))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  private func fixture(_ scratch: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: scratch)
    try AcmeDocAttachments.attach("rules", to: "app", in: store)
    return store
  }

  private func stored(_ field: String, in store: DatabaseStore) throws -> Data? {
    try store.read { try Data.fetchOne($0, sql: "SELECT CAST(\(field) AS BLOB) FROM doc_rev") }
  }
}
