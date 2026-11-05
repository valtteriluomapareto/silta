import Darwin
import Foundation
import GRDB

/// Fixed-location complete snapshots. Publication never replaces an existing backup.
struct StorageBackup {
  let home: URL

  /// The daily backup (`reuseExisting`) runs inside the write transaction and the
  /// pre-migration one under the migration lock, so each kind stages under one fixed
  /// name, and a crashed attempt's leftover is replaced by the next attempt.
  /// The staged file is flushed to disk before it is linked, so a published backup is
  /// complete; with `reuseExisting`, one already published under `name` counts as done.
  /// `staging` names the staging file when the caller is neither of those two kinds.
  func snapshot(name: String, reuseExisting: Bool = false, staging: String? = nil) throws -> URL {
    let directory = home.appending(path: "backups")
    let destination = directory.appending(path: name)
    let temporary = directory.appending(
      path: staging ?? (reuseExisting ? "daily.pending" : "migration.pending"))
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try? fm.removeItem(at: temporary)  // a crashed attempt's leftover, when there is one
      defer { try? fm.removeItem(at: temporary) }  // best-effort cleanup of an unpublished snapshot
      var config = Configuration()
      // SQLite needs write access to initialize WAL sidecars, even though VACUUM INTO
      // only reads the source database's contents.
      config.busyMode = .timeout(5)
      let source = try DatabaseQueue(
        path: home.appending(path: "silta.db").path, configuration: config)
      try source.writeWithoutTransaction { db in
        try db.execute(sql: "VACUUM INTO ?", arguments: [temporary.path])
      }
      let staged = open(temporary.path, O_RDONLY)
      guard staged >= 0 else { throw StorageError.backupFailed }
      defer { close(staged) }
      // Network volumes may not support F_FULLFSYNC; plain fsync is what SQLite falls back to.
      guard fcntl(staged, F_FULLFSYNC) == 0 || fsync(staged) == 0 else {
        throw StorageError.backupFailed
      }
      do {
        try fm.linkItem(at: temporary, to: destination)
      } catch {
        guard reuseExisting, try isRegularFile(destination) else { throw error }
      }
      return destination
    } catch {
      throw StorageError.backupFailed
    }
  }

  func prune() throws {
    let directory = home.appending(path: "backups")
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    .filter {
      guard
        $0.lastPathComponent.wholeMatch(
          of: /silta-[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-before-[A-Za-z0-9]+-[0-9]+)?\.db/) != nil
      else { return false }
      return try isRegularFile($0)
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in backups.dropLast(7) {
      try FileManager.default.removeItem(at: file)
    }
  }

  private func isRegularFile(_ file: URL) throws -> Bool {
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}
