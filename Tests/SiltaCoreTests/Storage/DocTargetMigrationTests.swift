import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTargetMigrationTests {
  static var fixture: URL {
    DocsMigrationTests.fixture.deletingLastPathComponent().appending(path: "storage-v7.db")
  }

  @Test func v7HistoryRemainsUnknownWithoutChangingExistingColumns() throws {
    try withScratchDirectory { home in
      let store = try DocAuditMigrationTests.copy(Self.fixture, to: home)
      var config = Configuration()
      config.readonly = true
      let queue = try DatabaseQueue(path: store.path, configuration: config)
      try queue.read { db in
        #expect(
          try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            == ["v1", "v2", "v3", "v4", "v5", "v6", "v7"])
        #expect(
          try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == 6)
        #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
        let decision = try #require(
          try Row.fetchOne(db, sql: "SELECT triaged_at,triaged_by FROM doc_rev WHERE id=14"))
        #expect(decision["triaged_at"] as String? == "2023-11-14T22:14:00.000Z")
        #expect(decision["triaged_by"] as String? == "human:acme")
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE triaged_at IS NULL") == 4)
      }
      let columns = try DocAuditMigrationTests.columns(store.path, table: "doc_rev")
      #expect(!columns.contains("about_targets"))
      let before = try DocAuditMigrationTests.rows(store.path, table: "doc_rev", columns: columns)
      try store.initialize()
      #expect(
        try DocAuditMigrationTests.rows(store.path, table: "doc_rev", columns: columns) == before)
      try store.read { (db: Database) throws in
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE about_targets IS NOT NULL")
            == 0)
        #expect(
          try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == 9)
      }
      let backup = home.appending(path: "backups/silta-2023-11-14-before-v8-1700000000000.db")
      #expect(
        !(try DocAuditMigrationTests.columns(backup.path, table: "doc_rev")).contains(
          "about_targets"))
      #expect(
        try DocAuditMigrationTests.rows(backup.path, table: "doc_rev", columns: columns) == before)
    }
  }
}
