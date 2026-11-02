import Foundation
import GRDB

/// Fixed-location complete snapshots. Publication never replaces an existing backup.
struct StorageBackup {
  let home: URL
  let ids: any IDGenerator

  func snapshot(name: String, at timestamp: Date) throws -> URL {
    let directory = home.appending(path: "backups")
    let destination = directory.appending(path: name)
    let temporary = directory.appending(path: "pending-\(try ids.next(at: timestamp)).db")
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: temporary) }  // best-effort cleanup of an unpublished snapshot
      var config = Configuration()
      config.readonly = true
      config.busyMode = .timeout(5)
      let source = try DatabaseQueue(
        path: home.appending(path: "silta.db").path, configuration: config)
      try source.writeWithoutTransaction { db in
        try db.execute(sql: "VACUUM INTO ?", arguments: [temporary.path])
      }
      do {
        try fm.linkItem(at: temporary, to: destination)
      } catch {
        guard fm.fileExists(atPath: destination.path) else { throw error }
        let existing = try DatabaseQueue(path: destination.path, configuration: config)
        let valid = try existing.read {
          try String.fetchOne($0, sql: "PRAGMA integrity_check") == "ok"
        }
        guard valid else { throw StorageError.backupFailed }
      }
      return destination
    } catch {
      throw StorageError.backupFailed
    }
  }

  func prune() throws {
    let directory = home.appending(path: "backups")
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter {
      $0.lastPathComponent.wholeMatch(
        of: /silta-[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-before-v1-[0-9A-HJKMNP-TV-Z]{26})?\.db/) != nil
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in backups.dropLast(7) {
      try FileManager.default.removeItem(at: file)
    }
  }
}
