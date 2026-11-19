import Darwin
package import Foundation
package import GRDB
import Synchronization

/// A concrete database seam. Construction performs no I/O; reads never initialize or migrate.
package final class DatabaseStore: Sendable {
  /// Integer schema compatibility supported by writes from this binary.
  package static let writerVersion = 8
  /// Absolute path of the truth database.
  package let path: String
  private let home: URL
  private let clock: any Clock
  private let jitter: @Sendable () -> UInt64
  private let readBusyTimeout: TimeInterval
  /// Writes only to an existing, current database: never creates or migrates one.
  private let existingOnly: Bool
  private let writer = Mutex<DatabaseQueue?>(nil)

  /// Configures the fixed database/backup locations without opening or creating files.
  /// With `existingOnly`, writes refuse a missing database or a pending migration.
  package init(
    home: URL, clock: any Clock, jitter: @escaping @Sendable () -> UInt64,
    readBusyTimeout: TimeInterval = 5, existingOnly: Bool = false
  ) {
    self.home = home
    self.clock = clock
    self.existingOnly = existingOnly
    self.jitter = jitter
    self.readBusyTimeout = readBusyTimeout
    path = home.appending(path: "silta.db").path
  }

  /// Creates the database and applies pending migrations after a complete snapshot.
  /// A platform file lock serializes initialization across processes. Failures are coded.
  package func initialize() throws {
    try initialize(creating: !existingOnly)
  }

  /// Initializes an existing store without creating a database at a new location.
  func initialize(creating: Bool) throws {
    do {
      try writer.withLock { cached in
        if !creating { try requireExistingFile() }
        guard cached == nil else { return }
        if creating {
          let directory = try DirectoryPath.open(DirectoryPath.canonicalHome(home), creating: true)
          close(directory)
        }
        let descriptor = Darwin.open(
          home.appending(path: "migration.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
          0o600)
        guard descriptor >= 0 else { throw StorageError.fileFailure(errno, at: home.path) }
        defer { close(descriptor) }
        // Covers WAL setup and discovery as well as migration execution across processes.
        guard flock(descriptor, LOCK_EX) == 0 else {
          throw StorageError.fileFailure(errno, at: home.path)
        }
        defer { flock(descriptor, LOCK_UN) }
        try prepareDatabaseFile(creating: creating)
        var config = Configuration()
        config.prepareDatabase { TaskVisibility.register(in: $0) }
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: path, configuration: config)
        let migrator = StorageSchema.migrator
        let pending = try queue.read(Self.pendingMigration)
        if existingOnly, pending != nil { throw StorageError.migrationRequired }
        try queue.writeWithoutTransaction { db in
          try Self.requireWAL(try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL"))
        }
        if let pending {
          // A name that already exists (a retry at the same instant) refuses, never replaces.
          let timestamp = clock.now()
          let milliseconds = Int64(timestamp.timeIntervalSince1970 * 1000)
          let name = "silta-\(utcDay(timestamp))-before-\(pending)-\(milliseconds).db"
          let backup = StorageBackup(home: home)
          _ = try backup.snapshot(name: name)
          try migrator.migrate(queue)
          try? backup.prune(on: utcDay(timestamp), keeping: [name])  // retention after commit
        }
        cached = queue
      }
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

  private func prepareDatabaseFile(creating: Bool) throws {
    if creating {
      let file = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      if file >= 0 {
        close(file)
      } else if errno != EEXIST {
        throw StorageError.fileFailure(errno, at: path)
      }
    }
    try requireExistingFile()
  }

  /// Confirms the fixed database entry is an existing regular file.
  private func requireExistingFile() throws {
    var file = stat()
    guard lstat(path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else {
      throw StorageError.cannotOpen
    }
  }

  /// The first migration this binary still has to apply, after the writer floor check.
  private static func pendingMigration(_ db: Database) throws -> String? {
    let migrator = StorageSchema.migrator
    if try db.tableExists("meta") { try checkWriterVersion(db) }
    let applied = try migrator.appliedIdentifiers(db)
    let pending = migrator.migrations.first { !applied.contains($0) }
    // A newer binary's schema is never migrated here; min_writer_version alone
    // decides whether this binary may still write to it (D32). One that also
    // lacks a migration of ours has diverged, and has none of our tables to trust.
    if try migrator.hasBeenSuperseded(db) {
      guard pending == nil else { throw StorageError.schemaTooNew }
      return nil
    }
    return pending
  }

  /// Commits one BEGIN IMMEDIATE transaction, retrying raw SQLite busy failures at most
  /// three times. The closure must perform database-only work: a rolled-back attempt
  /// can run again.
  /// Checks writer compatibility and completes the required daily snapshot before calling the body.
  /// With `rollingBack`, the body's result is returned and its transaction rolled back.
  /// A caller that also publishes a snapshot supplies its path through `keepingBackup`.
  package func write<T>(
    rollingBack: Bool = false, keepingBackup: ((T) -> String?)? = nil,
    _ body: (StorageTransaction) throws -> T
  ) throws -> T {
    var kept: T?
    do {
      try initialize()
      guard let queue = writer.withLock({ $0 }) else { throw StorageError.internalMisuse }
      let backup = StorageBackup(home: home)
      let (result, day) = try withStorageRetry(clock: clock, jitter: jitter) {
        try queue.write { db in
          try Self.checkWriterVersion(db)
          // WAL lock acquisition alone does not prove the main file is writable.
          guard FileManager.default.isWritableFile(atPath: path) else {
            throw StorageError.accessDenied
          }
          let day = utcDay(clock.now())
          let previous = try String.fetchOne(
            db, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
          guard let previous else { throw StorageError.corrupt }
          if previous != day {
            _ = try backup.snapshot(name: "silta-\(day).db", reuseExisting: true)
            try db.execute(
              sql: "UPDATE meta SET value=? WHERE key='last_backup_day'", arguments: [day])
          }
          let value = try body(StorageTransaction(database: db))
          guard !rollingBack else {
            kept = value
            throw RollBack()
          }
          return (value, day)
        }
      }
      var keeping: Set<String> = ["silta-\(day).db"]
      if let path = keepingBackup?(result) { keeping.insert(URL(filePath: path).lastPathComponent) }
      try? backup.prune(on: day, keeping: keeping)  // best-effort retention
      return result
    } catch is RollBack {
      guard let kept else { throw StorageError.internalMisuse }  // set before every RollBack
      return kept
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

  private struct RollBack: Error {}  // guard:allow-error ends a rolled-back write in this file

  /// Reads require WAL; a filesystem that silently keeps another journal mode is unusable.
  static func requireWAL(_ mode: String?) throws {
    guard mode == "wal" else { throw StorageError.walRefused }
  }

  /// Refuses when a migration raised `min_writer_version` past this binary's.
  private static func checkWriterVersion(_ db: Database) throws {
    let version = try Int.fetchOne(
      db, sql: "SELECT value FROM meta WHERE key='min_writer_version'")
    guard let version else { throw StorageError.corrupt }
    guard version <= writerVersion else { throw StorageError.schemaTooNew }
  }

  /// Reads only an existing database through a read-only transaction, never migrating.
  /// Missing/unreadable files and attempts to mutate in the closure are coded failures.
  package func read<T>(_ body: (Database) throws -> T) throws -> T {
    do {
      let queue = try openReader()
      return try queue.read(body)
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

  /// Opens an existing store with the same read-only WAL recovery policy as ordinary reads.
  func openReader() throws -> DatabaseQueue {
    do {
      var config = Configuration()
      config.prepareDatabase { TaskVisibility.register(in: $0) }
      config.readonly = true
      config.busyMode = .timeout(readBusyTimeout)
      let queue: DatabaseQueue
      do {
        queue = try DatabaseQueue(path: path, configuration: config)
      } catch let error as DatabaseError
        where error.resultCode == .SQLITE_CANTOPEN
        && FileManager.default.isWritableFile(atPath: path)
      {
        // A read-only connection cannot recreate `-wal`/`-shm`, which another SQLite
        // client removes when it closes the database last. A read-write connection can;
        // `DatabaseQueue.read` still runs the body query-only. A read-only `silta.db` is
        // left alone: recreated files would inherit its mode and block later writes.
        config.readonly = false
        queue = try DatabaseQueue(path: path, configuration: config)
      }
      return queue
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

}
