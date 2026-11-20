import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension StorageSchemaTests {
  private static let writerFloors = [1, 2, 3, 4, 5, 6, 6, 8, 9]

  @Test func everyMigrationMatchesItsFrozenCatalogAndWriterFloor() throws {
    let migrator = StorageSchema.migrator
    let versions = Self.writerFloors.indices.map { "v\($0 + 1)" }
    try #require(migrator.migrations == versions)
    let queue = try DatabaseQueue()
    let root = DocsMigrationTests.fixture.deletingLastPathComponent()
      .appending(path: "storage-schema")
    let decoder = JSONDecoder()
    for (version, floor) in zip(versions, Self.writerFloors) {
      try migrator.migrate(queue, upTo: version)
      let golden = try String(contentsOf: root.appending(path: "\(version).jsonl"), encoding: .utf8)
      let expected = try golden.split(separator: "\n").map {
        try decoder.decode([String?].self, from: Data($0.utf8))
      }
      try queue.read { db in
        let actual = try Self.catalog(db)
        if version == "v1" {
          let metadata = try String.fetchAll(
            db, sql: "SELECT key || '=' || value FROM meta ORDER BY key")
          #expect(metadata == ["change_seq=0", "last_backup_day=", "min_writer_version=1"])
        }
        #expect(actual.count == expected.count, "Migration \(version)")
        for (row, frozen) in zip(actual, expected) {
          #expect(row == frozen, "Migration \(version), object \(row[1] ?? "")")
        }
        #expect(
          try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
            == floor,
          "Migration \(version)")
      }
    }
  }

  @Test(arguments: Array(1...8))
  func migratedCatalogMatchesFreshStore(version: Int) throws {
    try withScratchDirectory { scratch in
      let fresh = Self.store(scratch.appending(path: "fresh"))
      try fresh.initialize()
      let fixtures = DocsMigrationTests.fixture.deletingLastPathComponent()
      let store = try DocAuditMigrationTests.copy(
        fixtures.appending(path: "storage-v\(version).db"), to: scratch)
      let hasCanary = version >= 4
      let canaryColumns = hasCanary ? ["id", "future"] : ["id", "body_md"]
      let before = try DocAuditMigrationTests.rows(
        store.path, table: "doc_rev", columns: canaryColumns)
      let tasks = try DocAuditMigrationTests.rows(
        store.path, table: "task", columns: ["uid", "seq", "title"])
      try #require(!tasks.isEmpty)
      if hasCanary { #expect(before.contains { $0.contains("retained current") }) }
      try store.initialize()
      #expect(
        try fresh.read { try Self.catalog($0) }
          == store.read { try Self.catalog($0, legacyCanary: hasCanary) })
      #expect(
        try DocAuditMigrationTests.rows(store.path, table: "doc_rev", columns: canaryColumns)
          == before)
      #expect(
        try DocAuditMigrationTests.rows(
          store.path, table: "task", columns: ["uid", "seq", "title"])
          == tasks)
      try store.read { (db: Database) throws in
        #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
      }
    }
  }

  @Test(arguments: [1, 2, 3, 5])
  func historicalFixtureKeepsItsWriterFloorAndOriginalData(version: Int) throws {
    var options = Configuration()
    options.readonly = true
    let file = DocsMigrationTests.fixture.deletingLastPathComponent()
      .appending(path: "storage-v\(version).db")
    let queue = try DatabaseQueue(path: file.path, configuration: options)
    try queue.read { (db: Database) throws in
      #expect(
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
          == (1...version).map { "v\($0)" })
      #expect(
        try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
          == version)
      let expected = version == 5 ? "Acme v5 writer evidence" : "Acme historical work"
      #expect(
        try Int.fetchOne(db, sql: "SELECT count(*) FROM task WHERE title=?", arguments: [expected])
          == 1)
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
    }
  }

  private static func catalog(_ db: Database, legacyCanary: Bool = false) throws -> [[String?]] {
    try Row.fetchAll(db, sql: "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
      .map { row in
        let name: String = row["name"]
        var sql: String? = row["sql"]
        if legacyCanary && name == "doc_rev" {
          // Frozen stores carry this deliberate unknown-column canary, whose data is tested above.
          sql = sql?.replacingOccurrences(of: ", future TEXT,", with: ",", options: .literal)
        }
        return [row["type"], name, row["tbl_name"], sql]
      }
  }
}
