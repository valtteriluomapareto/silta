import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension DogfoodReportTests {
  @Test func documentCollectionCannotReadPrivateFields() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try Self.document(store, created: "2023-11-14T00:00:00.000Z")
      try store.write {
        try $0.database.execute(
          sql: """
            ALTER TABLE doc_rev RENAME TO private_doc_rev;
            CREATE VIEW doc_rev AS SELECT doc_id,state,actor,created_at,triaged_at,triaged_by FROM private_doc_rev;
            ALTER TABLE doc RENAME TO private_doc;
            CREATE VIEW doc AS SELECT id,workspace_id FROM private_doc;
            ALTER TABLE approval RENAME TO private_approval;
            CREATE VIEW approval AS SELECT workspace,actor,command,created_at FROM private_approval;
            """)
      }
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(report.contains("Known submissions created in range: 1."))
    }
  }

  @Test func preAuditColumnsReportUnknownWithoutMigration() throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try Self.document(store, state: "accepted", created: "2023-11-14T00:00:00.000Z")
      try store.write { tx in
        try tx.database.execute(
          sql: """
            ALTER TABLE doc_rev DROP COLUMN triaged_at;
            ALTER TABLE doc_rev DROP COLUMN triaged_by;
            DELETE FROM grdb_migrations WHERE identifier='v7';
            """)
      }
      let before = try store.read { db in
        try String.fetchAll(
          db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
      }
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(
        report.contains(
          "Unattributed terminal history created in range: 1 (direct or legacy; not known proposal decisions)."
        ))
      #expect(
        report.contains("Known decisions in range: 0 accepted; 0 rejected; acceptance rate n/a."))
      #expect(
        try store.read { db in
          try String.fetchAll(
            db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
        } == before)
      #expect(
        try store.read {
          try String.fetchOne(
            $0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier DESC LIMIT 1")
        } == "v6")
    }
  }

  @Test(arguments: [false, true])
  func failedDocMetadataReadPublishesNothing(privateReport: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try Self.setup(scratch)
      try store.write {
        try $0.database.execute(sql: "ALTER TABLE doc_rev RENAME TO missing_doc_rev")
      }
      let tools = try Self.tools(scratch)
      let flags = (privateReport ? ["--ws", "silta"] : []) + ["--since", "2023-11-14"]
      let result = try Self.run(flags, scratch: scratch, tools: tools)
      #expect(result.termination != .exit(0) && result.stdout.isEmpty)
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/reports").path))
    }
  }

  @Test func emptyKnownDecisionRateIsUnavailable() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      let report = try Self.docReport(scratch, tools: tools)
      #expect(
        report.contains("Known decisions in range: 0 accepted; 0 rejected; acceptance rate n/a."))
      #expect(report.contains("Decision wait: median n/a; maximum n/a."))
    }
  }
}
