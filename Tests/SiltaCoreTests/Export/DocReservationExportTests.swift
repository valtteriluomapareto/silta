import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.timeLimit(.minutes(1)))
struct DocReservationExportTests {
  static func counterOnly(_ home: URL) throws -> DatabaseStore {
    let store = try DocAuditMigrationTests.copy(DocAuditMigrationTests.fixture, to: home)
    try store.initialize()
    try store.write { tx in
      try tx.database.execute(
        sql: """
          DELETE FROM comment WHERE doc_rev_id IS NOT NULL;
          DELETE FROM link WHERE from_kind IN ('doc','doc_rev') OR to_kind IN ('doc','doc_rev');
          DELETE FROM doc_verification;
          DELETE FROM doc_rev;
          DELETE FROM doc;
          """)
    }
    return store
  }

  @Test func formatOneRefusesReservedHistoryWithoutDocuments() throws {
    try withScratchDirectory { home in
      let store = try Self.counterOnly(home)
      let before = try DocStoreTests.snapshot(store)
      let error = ExportError.unsupported("reserved doc revision history")
      #expect(throws: error) {
        _ = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      }
      #expect(try DocStoreTests.snapshot(store) == before)
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      Golden.forTests().check(text.stderr + json.stdout, "doc-reservation-export-error.txt")
    }
  }

  @Test func emptyWorkspaceAndOtherWorkspaceReservationsRemainExportable() throws {
    try withScratchDirectory { home in
      let store = try Self.counterOnly(home)
      try store.write { tx in
        try tx.database.execute(sql: "DELETE FROM seq_counter WHERE scope='doc_rev:1:push-rules'")
      }
      _ = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO workspace(id,uid,slug,name,task_prefix)
            VALUES(11,'beta','beta','Beta','BE');
            INSERT INTO seq_counter(scope,next) VALUES('doc_rev:11:orphan',20);
            INSERT INTO seq_counter(scope,next) VALUES('docXrev:1:other',20);
            """)
      }
      _ = try store.read { try ExportSnapshot.read($0, workspace: "acme") }
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func actualV6ExporterRefusesUnknownCounterOnlySchema() throws {
    let binary = try #require(ProcessInfo.processInfo.environment["SILTA_V6_BINARY"])
    try withScratchDirectory { home in
      let store = try Self.counterOnly(home)
      let before = try DocStoreTests.snapshot(store)
      let output = home.appending(path: "exports")
      let result = try SiltaBinary.runProcess(
        URL(filePath: binary), ["--json", "--ws", "acme", "export", "--to", output.path], in: home,
        environment: ["SILTA_HOME": home.path, "SILTA_ACTOR": "agent:codex:acme"])
      #expect(result.termination == .exit(9))
      #expect(result.stdout.contains("newer"))
      #expect(!FileManager.default.fileExists(atPath: output.path))
      #expect(try DocStoreTests.snapshot(store) == before)
    }
  }
}
