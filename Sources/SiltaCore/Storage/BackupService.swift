import Darwin
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
    try store.initialize(creating: false)
    let lock = try BoundedFileLock(home.appending(path: "backup.lock"), clock: clock)
    defer { withExtendedLifetime(lock) {} }
    let backup = StorageBackup(home: home)
    do {
      try backup.cleanManualStaging()
      let parent = try DirectoryPath.open(backup.home)
      defer { close(parent) }
      let work = try DirectoryPath.makeTemporary(in: parent, prefix: ".manual-")
      defer { _ = removefileat(parent, work, nil, UInt32(REMOVEFILE_RECURSIVE)) }
      let date = clock.now()
      let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
      let token = String(work.dropFirst(".manual-".count))
      let name = "silta-\(utcDay(date))-manual-\(milliseconds)-\(token).db"
      let path = try backup.snapshot(
        name: name, staging: work)
      try backup.prune(on: utcDay(date), manual: true, keeping: [name])
      return BackupResult(path: path.path)
    } catch { throw StorageError.backupFailed }
  }
}
