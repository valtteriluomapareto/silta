import Darwin
package import Foundation
package import GRDB
import Synchronization

/// A concrete database seam. Construction performs no I/O; reads never initialize or migrate.
package final class DatabaseStore: Sendable {
  /// Integer schema compatibility supported by writes from this binary.
  package static let writerVersion = 1
  /// Absolute path of the truth database.
  package let path: String
  private let home: URL
  private let clock: any Clock
  private let ids: any IDGenerator
  private let jitter: @Sendable () -> UInt64
  private let writer = Mutex<DatabaseQueue?>(nil)

  /// Configures the fixed database/backup locations without opening or creating files.
  package init(
    home: URL, clock: any Clock, ids: any IDGenerator,
    jitter: @escaping @Sendable () -> UInt64 = { UInt64.random(in: 10...50) }
  ) {
    self.home = home
    self.clock = clock
    self.ids = ids
    self.jitter = jitter
    path = home.appending(path: "silta.db").path
  }

  /// Creates the database and applies pending migrations after a complete snapshot.
  /// A platform file lock serializes initialization across processes. Failures are coded.
  package func initialize() throws {
    do {
      try writer.withLock { cached in
        guard cached == nil else { return }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
          home.appending(path: "migration.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw StorageError.unavailable }
        defer { close(descriptor) }
        // Covers WAL setup and discovery as well as migration execution across processes.
        guard flock(descriptor, LOCK_EX) == 0 else { throw StorageError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: path, configuration: config)
        let migrator = StorageSchema.migrator
        let pending = try queue.read { db in
          guard try !migrator.hasBeenSuperseded(db) else { throw StorageError.schemaTooNew }
          if try db.tableExists("meta") {
            let version = try Int.fetchOne(
              db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
            guard let version else { throw StorageError.unavailable }
            guard version <= Self.writerVersion else { throw StorageError.schemaTooNew }
          }
          return try !migrator.hasCompletedMigrations(db)
        }
        try queue.writeWithoutTransaction { db in
          guard try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL") == "wal" else {
            throw StorageError.unavailable
          }
        }
        if pending {
          let timestamp = clock.now()
          let day = String(timestamp.formatted(.iso8601).prefix(10))
          let name = "silta-\(day)-before-v1-\(try ids.next(at: timestamp)).db"
          let backup = StorageBackup(home: home, ids: ids)
          _ = try backup.snapshot(name: name, at: timestamp)
          try migrator.migrate(queue)
          try? backup.prune()  // best-effort retention after the committed migration
        }
        cached = queue
      }
    } catch {
      throw StorageError.mapped(error)
    }
  }

  /// Commits one BEGIN IMMEDIATE transaction, retrying raw SQLite busy failures at most three times.
  /// The closure must perform database-only work: a rolled-back attempt can run again.
  /// Checks writer compatibility and completes the required daily snapshot before calling the body.
  package func write<T>(_ body: (StorageTransaction) throws -> T) throws -> T {
    do {
      try initialize()
      guard let queue = writer.withLock({ $0 }) else { throw StorageError.unavailable }
      let backup = StorageBackup(home: home, ids: ids)
      let result = try withStorageRetry(clock: clock, jitter: jitter) {
        try queue.write { db in
          let version = try Int.fetchOne(
            db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
          guard let version else { throw StorageError.unavailable }
          guard version <= Self.writerVersion else { throw StorageError.schemaTooNew }
          // WAL lock acquisition alone does not prove the main file is writable.
          guard FileManager.default.isWritableFile(atPath: path) else {
            throw StorageError.unavailable
          }
          let timestamp = clock.now()
          let day = String(timestamp.formatted(.iso8601).prefix(10))
          let previous = try String.fetchOne(
            db, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
          guard let previous else { throw StorageError.unavailable }
          if previous != day {
            _ = try backup.snapshot(name: "silta-\(day).db", at: timestamp, reuseExisting: true)
            try db.execute(
              sql: "UPDATE meta SET value=? WHERE key='last_backup_day'", arguments: [day])
          }
          return try body(StorageTransaction(database: db))
        }
      }
      try? backup.prune()  // best-effort retention cannot invalidate a committed write
      return result
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error)
    }
  }

  /// Reads only an existing database through a read-only connection and transaction.
  /// Missing/unreadable files and attempts to mutate in the closure are coded failures.
  package func read<T>(_ body: (Database) throws -> T) throws -> T {
    do {
      var config = Configuration()
      config.readonly = true
      config.busyMode = .timeout(5)
      let queue = try DatabaseQueue(path: path, configuration: config)
      return try queue.read(body)
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error)
    }
  }
}
