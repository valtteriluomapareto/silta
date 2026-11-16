import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocTargetMigrationTests {
  @Test func v7HistoryRemainsUnknownWithoutChangingExistingColumns() throws {
    try withScratchDirectory { home in
      let store = try DocAuditMigrationTests.copy(DocAuditMigrationTests.fixture, to: home)
      let queue = try DatabaseQueue(path: store.path)
      try StorageSchema.migrator.migrate(queue, upTo: "v7")
      let columns = try DocAuditMigrationTests.columns(store.path, table: "doc_rev")
      let before = try DocAuditMigrationTests.rows(store.path, table: "doc_rev", columns: columns)
      try store.initialize()
      #expect(
        try DocAuditMigrationTests.rows(store.path, table: "doc_rev", columns: columns) == before)
      try store.read { (db: Database) throws in
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM doc_rev WHERE about_targets IS NOT NULL")
            == 0)
        #expect(
          try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'") == 8)
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
