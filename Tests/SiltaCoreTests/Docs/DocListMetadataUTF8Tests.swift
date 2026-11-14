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

  @Test func listIdentityBytesNeverRetargetAnotherDocument() throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let slug = "rules\u{0}tail"
      try addIdentity(slug, in: store)
      let original = try store.read {
        try Data.fetchAll($0, sql: "SELECT CAST(slug AS BLOB) FROM doc ORDER BY id")
      }
      #expect(original == [Data("rules".utf8), Data(slug.utf8)])
      let before = try DocVerificationPreparationTests.truth(store)
      for flags in [["--archived"], ["--archived", "--offset", "1", "--limit", "1"]] {
        let result = try SiltaBinary.run(
          ["--ws", "acme", "doc", "ls"] + flags + ["--json"], in: scratch)
        #expect(result.termination == .exit(0) && result.stderr.isEmpty)
        let object = try #require(
          try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let entries = try #require(data["entries"] as? [[String: Any]])
        let other = try #require(
          entries.first { ($0["output"] as? String)?.contains("Other snapshot") == true })
        let output = try #require(other["output"] as? String)
        let normal = "silta --ws 'acme' doc show 'doc:rules@1'"
        if entries.count == 2 {
          let ordinary = try #require(
            entries.first { ($0["output"] as? String)?.contains("Other snapshot") == false })
          #expect(ordinary["ref"] as? String == "doc:rules@1")
          #expect((ordinary["output"] as? String)?.contains(normal) == true)
        }
        #expect((other["ref"] as? String).map { Data($0.utf8) } == Data("doc:\(slug)@1".utf8))
        #expect(!output.contains(normal))
        #expect(output.contains("doc ls --archived"))
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(
        try store.read {
          try Data.fetchAll($0, sql: "SELECT CAST(slug AS BLOB) FROM doc ORDER BY id")
        } == original)
    }
  }

  private func addIdentity(_ slug: String, in store: DatabaseStore) throws {
    try store.write {
      try $0.database.execute(
        sql: """
          INSERT INTO doc(uid,workspace_id,slug,title,kind,current_rev,archived,
          created_at,updated_at)
          SELECT 'nul-doc',workspace_id,CAST(? AS TEXT),'Other projection','reference',1,1,
            created_at,updated_at FROM doc WHERE slug='rules';
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at,title,kind,about_refs)
          SELECT 'nul-revision',id,1,'Other body','accepted','human:acme','2023-11-14',
            'Other snapshot','reference','["app:api"]' FROM doc WHERE uid='nul-doc';
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
          created_by,created_at)
          SELECT 'nul-about',workspace_id,'doc',(SELECT id FROM doc WHERE uid='nul-doc'),rel,
            to_kind,to_id,created_by,created_at FROM link WHERE from_kind='doc';
          """, arguments: [Data(slug.utf8)])
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
