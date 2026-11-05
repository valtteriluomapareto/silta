import Dispatch
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct StorageWriteTests {
  static func make(_ home: URL, clock: FakeClock) -> DatabaseStore {
    DatabaseStore(home: home, clock: clock, jitter: { 7 })
  }

  static func insert(_ transaction: StorageTransaction, uid: String) throws -> Int64 {
    let seq = try transaction.nextSequence(scope: "acme")
    try transaction.database.execute(
      sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES(?,?,'Acme',?)",
      arguments: [uid, uid, uid])
    try transaction.recordChange(kind: "workspace", rowID: transaction.database.lastInsertedRowID)
    return seq
  }

  static func meta(_ store: DatabaseStore, _ key: String) throws -> String? {
    try store.read {
      try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key=?", arguments: [key])
    }
  }

  @Test func writerUsesImmediateAndRequiredPragmas() throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = Self.make(home, clock: clock)
      let statements = Mutex<[String]>([])
      try store.write { transaction in
        let db = transaction.database
        let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        #expect(foreignKeys == 1)
        let busyTimeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout")
        #expect(busyTimeout == 5000)
        db.trace { event in statements.withLock { $0.append(event.description) } }
      }
      try store.write { _ in () }
      #expect(
        statements.withLock { $0.filter { $0.hasPrefix("BEGIN ") } }
          == ["BEGIN IMMEDIATE TRANSACTION"])
    }
  }

  @Test func versionIsCheckedAtEveryWriteBeforeBackupOrBody() throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = Self.make(home, clock: clock)
      try store.write { _ in () }
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      clock.advance(milliseconds: 86_400_000)
      let external = try DatabaseQueue(path: store.path)
      try external.write {
        try StorageSchemaTests.requireNewerWriter(in: $0)
      }
      var called = false
      #expect(throws: StorageError.schemaTooNew) { try store.write { _ in called = true } }
      #expect(!called)
      #expect(try Self.meta(store, "change_seq") == "0")
      #expect(try Self.meta(store, "last_backup_day") == "2023-11-14")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "backups").path)
          .sorted() == backups.sorted())
    }
  }

  @Test func rollbackAndRetryKeepRowsSequencesAndChangesAtomic() throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = Self.make(home, clock: clock)
      #expect(throws: StorageError.internalMisuse) {
        try store.write { transaction in
          _ = try Self.insert(transaction, uid: "acme-rollback")
          throw StorageError.internalMisuse
        }
      }
      #expect(try Self.meta(store, "last_backup_day") == "")
      #expect(try Self.meta(store, "change_seq") == "0")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM seq_counter") } == 0)
      var attempts = 0
      let result = try store.write { transaction in
        attempts += 1
        let seq = try Self.insert(transaction, uid: "acme-success")
        if attempts < 4 { throw DatabaseError(resultCode: .SQLITE_BUSY) }
        return seq
      }
      #expect(result == 1)
      #expect(attempts == 4)
      #expect(abs(clock.now().timeIntervalSince(StorageSchemaTests.instant) - 0.021) < 0.000001)
      #expect(try Self.meta(store, "change_seq") == "1")
      try store.read { db in
        let workspaceCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM workspace")
        #expect(workspaceCount == 1)
        let nextSequence = try Int.fetchOne(db, sql: "SELECT next FROM seq_counter")
        #expect(nextSequence == 2)
        let loggedSequence = try Int.fetchOne(db, sql: "SELECT seq FROM change_log")
        #expect(loggedSequence == 1)
      }
    }
  }

  @Test func realBusyExhaustsThreeRetriesWithoutRunningBody() throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = Self.make(home, clock: clock)
      try store.write { try $0.database.execute(sql: "PRAGMA busy_timeout=0") }
      let external = try DatabaseQueue(path: store.path)
      var called = false
      try external.write { _ in
        do {
          #expect(throws: StorageError.busy) { try store.write { _ in called = true } }
        }
      }
      #expect(!called)
      #expect(abs(clock.now().timeIntervalSince(StorageSchemaTests.instant) - 0.021) < 0.000001)
      #expect(try Self.meta(store, "change_seq") == "0")
    }
  }

  @Test(arguments: [false, true]) func nonBusyAndCodedRefusalsAreNeverRetried(coded: Bool) throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = Self.make(home, clock: clock)
      var attempts = 0
      let expected: StorageError = coded ? .busy : .accessDenied
      #expect(throws: expected) {
        try store.write { _ in
          attempts += 1
          if coded { throw StorageError.busy }
          throw DatabaseError(resultCode: .SQLITE_READONLY, message: "Acme private SQL")
        }
      }
      #expect(attempts == 1)
      #expect(clock.now() == StorageSchemaTests.instant)
    }
  }

  @Test(
    arguments: [
      ResultCode.SQLITE_CONSTRAINT, .SQLITE_CONSTRAINT_CHECK, .SQLITE_CONSTRAINT_COMMITHOOK,
      .SQLITE_CONSTRAINT_FOREIGNKEY, .SQLITE_CONSTRAINT_FUNCTION, .SQLITE_CONSTRAINT_NOTNULL,
      .SQLITE_CONSTRAINT_PRIMARYKEY, .SQLITE_CONSTRAINT_TRIGGER, .SQLITE_CONSTRAINT_UNIQUE,
      .SQLITE_CONSTRAINT_VTAB, .SQLITE_CONSTRAINT_ROWID, .SQLITE_CONSTRAINT_PINNED,
      .SQLITE_CONSTRAINT_DATATYPE,
    ])
  func everyConstraintResultCodeIsItsOwnCodedError(code: ResultCode) {
    let underlying = DatabaseError(
      resultCode: code, message: "acme-private-value", sql: "acme-private-sql")
    let error = StorageError.mapped(underlying)
    #expect(error == .constraintViolation)
    #expect(!String(reflecting: error).contains("acme-private"))
    #expect(!error.message.contains("acme-private"))
  }

  @Test func callerCodedErrorIsPreserved() throws {
    try withScratchDirectory { home in
      let store = Self.make(home, clock: FakeClock(now: StorageSchemaTests.instant))
      var attempts = 0
      do {
        #expect(throws: SeamError.invalidTimestamp) {
          try store.write { _ in
            attempts += 1
            throw SeamError.invalidTimestamp
          }
        }
        #expect(attempts == 1)
      }
    }
  }

  @Test func dailySnapshotIsPreWriteOncePerUTCDayAndSurvivesReopen() throws {
    try withScratchDirectory { home in
      let clock = FakeClock(now: StorageSchemaTests.instant)
      let store = Self.make(home, clock: clock)
      #expect(try store.write { try Self.insert($0, uid: "acme-one") } == 1)
      let file = home.appending(path: "backups/silta-2023-11-14.db")
      let original = try Data(contentsOf: file)
      let snapshot = try DatabaseQueue(path: file.path)
      #expect(
        try snapshot.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
      let reopened = Self.make(home, clock: clock)
      #expect(try reopened.write { try Self.insert($0, uid: "acme-two") } == 2)
      #expect(try Data(contentsOf: file) == original)
      clock.advance(milliseconds: 86_400_000)
      #expect(try reopened.write { try Self.insert($0, uid: "acme-three") } == 3)
      let next = try DatabaseQueue(path: home.appending(path: "backups/silta-2023-11-15.db").path)
      #expect(try next.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 2)
      #expect(try Self.meta(store, "last_backup_day") == "2023-11-15")
    }
  }

  @Test func requiredDailyBackupFailureRefusesWrite() throws {
    try withScratchDirectory { home in
      let store = Self.make(home, clock: FakeClock(now: StorageSchemaTests.instant))
      try store.initialize()
      try FileManager.default.createDirectory(
        at: home.appending(path: "backups/silta-2023-11-14.db"), withIntermediateDirectories: false)
      var called = false
      #expect(throws: StorageError.backupFailed) { try store.write { _ in called = true } }
      #expect(!called)
      #expect(try Self.meta(store, "last_backup_day") == "")
      #expect(try Self.meta(store, "change_seq") == "0")
    }
  }

  @Test func concurrentStoresShareOnePreWriteSnapshot() throws {
    try withScratchDirectory { home in
      let stores = (0..<2).map { _ in
        Self.make(home, clock: FakeClock(now: StorageSchemaTests.instant))
      }
      let failures = Mutex<[String]>([])
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        do { _ = try stores[index].write { try Self.insert($0, uid: "acme-\(index)") } } catch {
          failures.withLock { $0.append(String(describing: error)) }
        }
      }
      #expect(failures.withLock { $0.isEmpty }, "\(failures.withLock { $0 })")
      let snapshot = try DatabaseQueue(
        path: home.appending(path: "backups/silta-2023-11-14.db").path)
      #expect(
        try snapshot.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
      #expect(try Self.meta(stores[0], "change_seq") == "2")
      #expect(try Self.meta(stores[0], "last_backup_day") == "2023-11-14")
    }
  }

  @Test func readOnlyWriterRefusesWithoutChangingState() throws {
    try withScratchDirectory { home in
      let database = home.appending(path: "silta.db")
      do { try StorageSchemaTests.store(home).initialize() }
      let files = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: database.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: home.path)  // restores scratch permissions
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: database.path)  // restores scratch permissions
      }
      let store = Self.make(home, clock: FakeClock(now: StorageSchemaTests.instant))
      #expect(throws: StorageError.accessDenied) {
        try store.write { try Self.insert($0, uid: "acme-refused") }
      }
      #expect(try Self.meta(store, "change_seq") == "0")
      #expect(try Self.meta(store, "last_backup_day") == "")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 0)
      let after = try FileManager.default.contentsOfDirectory(
        atPath: home.appending(path: "backups").path)
      #expect(after.sorted() == files.sorted())
    }
  }
}
