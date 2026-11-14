import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DocEvidenceReadCommandTests {
  @Test(arguments: [
    "body_md", "title", "kind", "message", "actor", "created_at", "triaged_by", "triaged_at",
    "source",
  ])
  func storedUTF8IsCompleteBeforeMasking(field: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let value = "-----BEGIN PRIVATE KEY-----\nprivate-acme\u{0}\n-----END PRIVATE KEY-----"
      let sql =
        field == "source"
        ? "UPDATE workspace SET task_prefix=CAST(? AS TEXT)"
        : "UPDATE doc_rev SET \(field)=CAST(? AS TEXT) WHERE rev=2"
      let read =
        field == "source"
        ? "SELECT CAST(task_prefix AS BLOB) FROM workspace WHERE id=1"
        : "SELECT CAST(\(field) AS BLOB) FROM doc_rev WHERE rev=2"
      try store.write { try $0.database.execute(sql: sql, arguments: [Data(value.utf8)]) }
      #expect(try store.read { try Data.fetchOne($0, sql: read) } == Data(value.utf8))
      let before = try truth(store)
      for flags in [[], ["--diff"], ["--lines", "1-400"]] {
        for json in [false, true] {
          let result = try run(flags, scratch, json: json)
          #expect(result.termination == .exit(0) && result.stderr.isEmpty)
          #expect(!result.stdout.contains("private-acme"))
          #expect(result.stdout.contains("[REDACTED:private_key]"))
        }
      }
      #expect(try truth(store) == before)
      #expect(try store.read { try Data.fetchOne($0, sql: read) } == Data(value.utf8))
    }
  }
  @Test(arguments: ["body_md", "message"])
  func harmlessStoredNULRetainsTheFollowingText(field: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let value = "Acme\u{0}tail"
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET \(field)=CAST(? AS TEXT) WHERE rev=2",
          arguments: [Data(value.utf8)])
      }
      let result = try run([], scratch, json: true)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      let envelope = try #require(
        try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      let data = try #require(envelope["data"] as? [String: Any])
      #expect((data["output"] as? String)?.contains(value) == true)
    }
  }

  @Test(arguments: ["body_md", "message", "source"])
  func invalidStoredUTF8RefusesWithoutPartialOutput(field: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let sql =
        field == "source"
        ? "UPDATE workspace SET task_prefix=CAST(X'41FF42' AS TEXT)"
        : "UPDATE doc_rev SET \(field)=CAST(X'41FF42' AS TEXT) WHERE rev=2"
      try store.write { try $0.database.execute(sql: sql) }
      for flags in [[], ["--diff"]] {
        let result = try run(flags, scratch, json: true)
        #expect(result.termination == .exit(9) && result.stderr.isEmpty)
        Golden.forTests().check(result.stdout, "doc-show-evidence-corrupt.json")
        #expect(!result.stdout.contains("doc:rules@2"))
      }
    }
  }

}
