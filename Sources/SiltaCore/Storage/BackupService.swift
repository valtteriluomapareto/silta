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
  /// Failures retain a coded cause. Daily and pre-restore backups stay outside manual retention.
  package static func backup(store: DatabaseStore, home: URL, clock: any Clock) throws
    -> BackupResult
  {
    try store.initialize(creating: false)
    let lock = try BoundedFileLock(home.appending(path: "backup.lock"), clock: clock)
    defer { withExtendedLifetime(lock) {} }
    let connection = try store.preparedWriter()
    let backup = StorageBackup(home: home, file: connection.file)
    do {
      do { try backup.cleanManualStaging() } catch { throw BackupFailure.destination }
      let parent = try DirectoryPath.open(backup.home)
      defer { close(parent) }
      let work = try DirectoryPath.makeTemporary(in: parent, prefix: ".manual-")
      let stage = try DirectoryPath.open(work, in: parent)
      defer {
        if DirectoryPath.matches(parent, path: backup.home),
          DirectoryPath.matches(stage, path: backup.home.appending(path: work))
        {
          _ = unlinkat(parent, work, AT_REMOVEDIR)
        }
        close(stage)
      }
      let date = clock.now()
      let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
      let token = String(work.dropFirst(".manual-".count))
      let name = "silta-\(utcDay(date))-manual-\(milliseconds)-\(token).db"
      let path = try backup.snapshot(
        name: name, staging: work, source: connection.queue, openedStage: stage)
      try? backup.prune(on: utcDay(date), manual: true, keeping: [name])  // best-effort
      return BackupResult(path: path.path)
    } catch let error as any CodedError {
      throw error
    } catch {
      throw BackupFailure.filesystem(StorageError.mapped(error, at: home.path))
    }
  }
}
