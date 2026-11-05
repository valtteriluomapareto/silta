import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// Helpers shared by the restore tests.
enum RestoreSupport {
  static let human = HumanApproval?.none

  /// Writes `files` as a tree under `directory` and returns it.
  @discardableResult
  static func write(_ files: [String: Data], to directory: URL) throws -> URL {
    for (path, data) in files {
      let file = directory.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file)
    }
    return directory
  }

  /// Every row of every table, as sorted text lines per table, so "unchanged" covers
  /// what export never writes too (machine paths, counters, change log, meta).
  static func dump(_ store: DatabaseStore) throws -> [String: [String]] {
    try store.read { db in
      var tables: [String: [String]] = [:]
      for table in try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
      {
        tables[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table)").map {
          $0.description
        }.sorted()
      }
      return tables
    }
  }

  static func backups(_ home: URL) throws -> Set<String> {
    let folder = home.appending(path: "backups")
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
  }

  /// Takes the day's backup, so later writes the same day publish no new daily file.
  static func settle(_ store: DatabaseStore) throws {
    try store.write { _ in () }
  }

  static func restore(
    _ tree: URL, into store: DatabaseStore, home: URL, workspace: String? = nil,
    approval: HumanApproval? = nil, dryRun: Bool = false, seed: UInt64 = 1
  ) throws -> RestoreReport {
    try RestoreService.restore(
      RestoreRequest(directory: tree, workspace: workspace, approval: approval, dryRun: dryRun),
      store: store, home: home, identity: (SeededIDGenerator(seed: seed), ExportFixture.instant))
  }

  /// The acme export of `store`, written under `directory/acme`.
  static func exportTree(_ store: DatabaseStore, to directory: URL) throws -> URL {
    try write(try ExportTreeTests.render(store), to: directory.appending(path: "acme"))
  }
}
