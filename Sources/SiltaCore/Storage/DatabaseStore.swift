import Darwin
package import Foundation
package import GRDB
import Synchronization

/// A concrete database seam. Construction performs no I/O; reads never initialize or migrate.
package final class DatabaseStore: Sendable {
  /// Integer schema compatibility supported by writes from this binary.
  package static let writerVersion = 9
  /// Absolute path of the truth database.
  package let path: String
  private let home: URL
  private let clock: any Clock
  private let jitter: @Sendable () -> UInt64
  private let readBusyTimeout: TimeInterval
  /// Writes only to an existing, current database: never creates or migrates one.
  private let existingOnly: Bool
  private let writer = Mutex<Connection?>(nil)

  struct Connection: Sendable {
    let queue: DatabaseQueue
    let file: DatabaseFile
  }

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
        if let connection = cached {
          do {
            try connection.file.requireCurrent(at: path)
            return
          } catch StorageError.databaseReplaced {
            cached = nil
            throw StorageError.databaseReplaced
          }
        }
        cached = try openWriter(creating: creating)
      }
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

  private func prepareDatabaseFile(in directory: Int32) throws {
    let descriptor = openat(
      directory, "silta.db", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if descriptor >= 0 {
      close(descriptor)
    } else if errno != EEXIST {
      throw StorageError.fileFailure(errno, at: path)
    }
  }

  private func openWriter(creating: Bool) throws -> Connection {
    let selected: DatabaseFile?
    do {
      selected = try DatabaseFile(at: path)
    } catch StorageError.cannotOpen where creating {
      selected = nil
    }
    let parent = selected?.directory ?? DirectoryPath.canonicalHome(home)
    let directory = try DirectoryPath.open(parent, creating: selected == nil)
    defer { close(directory) }
    let lockPath = parent.appending(path: "migration.lock").path
    let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw StorageError.fileFailure(errno, at: parent.path) }
    defer { close(descriptor) }
    // Aliases to the same target share its initialization lock.
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw StorageError.fileFailure(errno, at: parent.path)
    }
    defer { flock(descriptor, LOCK_UN) }
    guard DirectoryPath.matches(directory, path: parent) else {
      throw StorageError.databaseReplaced
    }
    if selected == nil, DatabaseFile.isMissing(path) { try prepareDatabaseFile(in: directory) }
    let file = try DatabaseFile(at: path)
    guard file.directory.path == parent.path, selected == nil || selected == file else {
      throw StorageError.databaseReplaced
    }
    return try openWriter(file)
  }

  private func openWriter(_ file: DatabaseFile) throws -> Connection {
    var config = Configuration()
    config.prepareDatabase { TaskVisibility.register(in: $0) }
    config.busyMode = .timeout(5)
    let queue = try DatabaseQueue(path: file.path, configuration: config)
    try file.requireCurrent(at: path)
    let pending = try queue.read(Self.pendingMigration)
    if existingOnly, pending != nil { throw StorageError.migrationRequired }
    try queue.writeWithoutTransaction { db in
      try Self.requireWAL(try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL"))
    }
    if let pending {
      try migrate(queue, file: file, pending: pending)
    }
    try file.requireCurrent(at: path)
    return Connection(queue: queue, file: file)
  }

  private func migrate(_ queue: DatabaseQueue, file: DatabaseFile, pending: String) throws {
    let timestamp = clock.now()
    let milliseconds = Int64(timestamp.timeIntervalSince1970 * 1000)
    let name = "silta-\(utcDay(timestamp))-before-\(pending)-\(milliseconds).db"
    let backup = StorageBackup(home: home, file: file)
    _ = try backup.snapshot(name: name, source: queue)
    try file.requireCurrent(at: path)
    try StorageSchema.migrator.migrate(queue)
    try? backup.prune(on: utcDay(timestamp), keeping: [name])  // retention after commit
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

  /// The already-open connection for snapshotting an existing store.
  func preparedWriter() throws -> Connection {
    guard let connection = writer.withLock({ $0 }) else { throw StorageError.internalMisuse }
    try connection.file.requireCurrent(at: path)
    return connection
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
      let connection = try preparedWriter()
      let file = connection.file
      let backup = StorageBackup(home: home, file: file)
      let (result, day) = try withStorageRetry(clock: clock, jitter: jitter) {
        try connection.queue.write { db in
          try file.requireCurrent(at: path)
          try Self.checkWriterVersion(db)
          // WAL lock acquisition alone does not prove the main file is writable.
          guard FileManager.default.isWritableFile(atPath: file.path) else {
            throw StorageError.accessDenied
          }
          let day = utcDay(clock.now())
          let previous = try String.fetchOne(
            db, sql: "SELECT value FROM meta WHERE key='last_backup_day'")
          guard let previous else { throw StorageError.corrupt }
          let daily = "silta-\(day).db"
          if previous != day || !backup.hasPublishedSnapshot(named: daily) {
            _ = try backup.snapshot(name: daily, reuseExisting: true)
            try db.execute(
              sql: "UPDATE meta SET value=? WHERE key='last_backup_day'", arguments: [day])
          }
          let value = try body(StorageTransaction(database: db, file: file))
          try file.requireCurrent(at: path)
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
      let connection = try openReader()
      return try connection.queue.read(body)
    } catch let error as any CodedError {
      throw error
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

  /// Opens an existing store with the same read-only WAL recovery policy as ordinary reads.
  func openReader() throws -> Connection {
    do {
      let file = try DatabaseFile(at: path)
      var config = Configuration()
      config.prepareDatabase { TaskVisibility.register(in: $0) }
      config.readonly = true
      config.busyMode = .timeout(readBusyTimeout)
      let queue: DatabaseQueue
      do {
        queue = try DatabaseQueue(path: file.path, configuration: config)
      } catch let error as DatabaseError
        where error.resultCode == .SQLITE_CANTOPEN
        && FileManager.default.isWritableFile(atPath: file.path)
      {
        // A read-only connection cannot recreate `-wal`/`-shm`, which another SQLite
        // client removes when it closes the database last. A read-write connection can;
        // `DatabaseQueue.read` still runs the body query-only. A read-only `silta.db` is
        // left alone: recreated files would inherit its mode and block later writes.
        config.readonly = false
        queue = try DatabaseQueue(path: file.path, configuration: config)
      }
      try file.requireCurrent(at: path)
      return Connection(queue: queue, file: file)
    } catch {
      throw StorageError.mapped(error, at: path)
    }
  }

}
