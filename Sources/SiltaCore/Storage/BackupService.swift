package import Foundation

/// The path of a complete whole-database snapshot.
package struct BackupResult: Encodable, Sendable {
  /// The published SQLite file, distinct for every invocation.
  package let path: String
}

/// On-demand snapshots have their own staging and seven-file retention class.
package enum BackupService {
  /// Publishes a whole-database snapshot without changing daily bookkeeping.
  /// Throws `StorageError` on failure; never removes daily or pre-restore backups.
  package static func backup(store: DatabaseStore, home: URL, clock: any Clock) throws
    -> BackupResult
  {
    try store.initialize()
    let lock = try BoundedFileLock(home.appending(path: "backup.lock"), clock: clock)
    defer { withExtendedLifetime(lock) {} }
    let directory = home.appending(path: "backups")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let work = try ExportService.ownDirectory(in: directory, prefix: ".manual-")
      defer { try? FileManager.default.removeItem(at: work) }  // only this invocation's staging
      let date = clock.now()
      let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
      let token = String(work.lastPathComponent.dropFirst(".manual-".count))
      let name = "silta-\(utcDay(date))-manual-\(milliseconds)-\(token).db"
      let backup = StorageBackup(home: home)
      let path = try backup.snapshot(
        name: name, staging: work.lastPathComponent + "/snapshot.pending")
      try backup.prune(manual: true, keeping: path)
      return BackupResult(path: path.path)
    } catch { throw StorageError.backupFailed }
  }
}
