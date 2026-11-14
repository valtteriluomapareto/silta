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
      for flags in [[], ["--diff"], ["--lines", "1:400"]] {
        for json in [false, true] {
          let result = try run(flags, scratch, json: json)
          #expect(result.termination == .exit(0) && result.stderr.isEmpty)
          withKnownIssue("Stored TEXT must retain its NUL and credential footer before masking") {
            #expect(!result.stdout.contains("private-acme"))
            #expect(result.stdout.contains("[REDACTED:private_key]"))
          }
        }
      }
      #expect(try truth(store) == before)
      #expect(try store.read { try Data.fetchOne($0, sql: read) } == Data(value.utf8))
    }
  }
}
