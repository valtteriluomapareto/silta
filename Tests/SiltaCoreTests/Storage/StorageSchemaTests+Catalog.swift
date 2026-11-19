import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension StorageSchemaTests {
  private static let writerFloors = [1, 2, 3, 4, 5, 6, 6, 8]

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

  @Test(arguments: [4, 6, 7])
  func migratedCatalogMatchesFreshStore(version: Int) throws {
    try withScratchDirectory { scratch in
      let fresh = Self.store(scratch.appending(path: "fresh"))
      try fresh.initialize()
      let fixtures = DocsMigrationTests.fixture.deletingLastPathComponent()
      let store = try DocAuditMigrationTests.copy(
        fixtures.appending(path: "storage-v\(version).db"), to: scratch)
      let canaryColumns = ["id", "future"]
      let before = try DocAuditMigrationTests.rows(
        store.path, table: "doc_rev", columns: canaryColumns)
      #expect(before.contains { $0.contains("retained current") })
      try store.initialize()
      #expect(
        try fresh.read { try Self.catalog($0) }
          == store.read { try Self.catalog($0, legacyCanary: true) })
      #expect(
        try DocAuditMigrationTests.rows(store.path, table: "doc_rev", columns: canaryColumns)
          == before)
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
