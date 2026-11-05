import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

/// Each storage failure class reports its own coded error and recovery (spec §16).
@Suite(.timeLimit(.minutes(1)))
struct StorageFailureClassTests {
  @Test(arguments: [
    (ResultCode.SQLITE_BUSY, StorageError.busy),
    (ResultCode.SQLITE_BUSY_TIMEOUT, .busy),
    (ResultCode.SQLITE_LOCKED, .locked),
    (ResultCode.SQLITE_LOCKED_SHAREDCACHE, .locked),
    (ResultCode.SQLITE_PROTOCOL, .locked),
    (ResultCode.SQLITE_PERM, .accessDenied),
    (ResultCode.SQLITE_READONLY, .accessDenied),
    (ResultCode.SQLITE_READONLY_ROLLBACK, .accessDenied),
    (ResultCode.SQLITE_READONLY_DIRECTORY, .accessDenied),
    (ResultCode.SQLITE_AUTH, .accessDenied),
    (ResultCode.SQLITE_IOERR, .ioFailure),
    (ResultCode.SQLITE_IOERR_READ, .ioFailure),
    (ResultCode.SQLITE_IOERR_WRITE, .ioFailure),
    (ResultCode.SQLITE_NOLFS, .ioFailure),
    (ResultCode.SQLITE_FULL, .diskFull),
    (ResultCode.SQLITE_IOERR_ACCESS, .accessDenied),
    (ResultCode.SQLITE_IOERR_NOMEM, .resourceExhausted),
    (ResultCode.SQLITE_CORRUPT, .corrupt),
    (ResultCode.SQLITE_CORRUPT_VTAB, .corrupt),
    (ResultCode.SQLITE_NOTADB, .corrupt),
    (ResultCode.SQLITE_FORMAT, .corrupt),
    (ResultCode.SQLITE_NOMEM, .resourceExhausted),
    (ResultCode.SQLITE_TOOBIG, .resourceExhausted),
    (ResultCode.SQLITE_ERROR, .internalMisuse),
    (ResultCode.SQLITE_INTERNAL, .internalMisuse),
    (ResultCode.SQLITE_INTERRUPT, .internalMisuse),
    (ResultCode.SQLITE_ABORT, .internalMisuse),
    (ResultCode.SQLITE_SCHEMA, .internalMisuse),
    (ResultCode.SQLITE_MISMATCH, .internalMisuse),
    (ResultCode.SQLITE_MISUSE, .internalMisuse),
    (ResultCode.SQLITE_RANGE, .internalMisuse),
    (ResultCode.SQLITE_CONSTRAINT, .constraintViolation),
    (ResultCode.SQLITE_CONSTRAINT_UNIQUE, .constraintViolation),
  ])
  func everyResultCodeMapsToItsFailureClass(code: ResultCode, expected: StorageError) {
    let underlying = DatabaseError(
      resultCode: code, message: "acme-private-value", sql: "acme-private-sql")
    let error = StorageError.mapped(underlying)
    #expect(error == expected, "\(code)")
    #expect(!String(reflecting: error).contains("acme-private"))
    #expect(!error.message.contains("acme-private"))
  }

  @Test func fileErrorsMapToTheirFailureClass() {
    #expect(StorageError.mapped(CocoaError(.fileWriteOutOfSpace)) == .diskFull)
    #expect(StorageError.mapped(CocoaError(.fileWriteNoPermission)) == .accessDenied)
    #expect(StorageError.mapped(CocoaError(.fileReadNoPermission)) == .accessDenied)
    #expect(StorageError.mapped(CocoaError(.fileNoSuchFile)) == .cannotOpen)
    #expect(StorageError.mapped(CocoaError(.fileLocking)) == .locked)
    #expect(StorageError.mapped(CocoaError(.fileReadCorruptFile)) == .corrupt)

    #expect(StorageError.mapped(POSIXError(.EACCES)) == .accessDenied)
    #expect(StorageError.mapped(POSIXError(.EPERM)) == .accessDenied)
    #expect(StorageError.mapped(POSIXError(.EROFS)) == .accessDenied)
    #expect(StorageError.mapped(POSIXError(.ENOSPC)) == .diskFull)
    #expect(StorageError.mapped(POSIXError(.EDQUOT)) == .diskFull)
    #expect(StorageError.mapped(POSIXError(.ENOENT)) == .cannotOpen)
    #expect(StorageError.mapped(POSIXError(.ENOLCK)) == .locked)
    #expect(StorageError.mapped(POSIXError(.EMFILE)) == .resourceExhausted)
    #expect(StorageError.mapped(POSIXError(.EIO)) == .ioFailure)
  }

  @Test func unknownErrorsStayUnknown() {
    struct Sample: Error {}
    #expect(StorageError.mapped(Sample()) == .unknown)
    #expect(StorageError.mapped(DatabaseError(resultCode: .SQLITE_EMPTY)) == .unknown)
  }

  @Test func everyClassHasItsOwnMessageAndActor() {
    let messages = StorageError.allCases.map(\.message)
    #expect(Set(messages).count == messages.count)
    #expect(StorageError.busy.code == .busy)
    #expect(StorageError.locked.code == .busy)
    for error in StorageError.allCases where error != .busy && error != .locked {
      #expect(error.code == .env, "\(error)")
      #expect(error.nextBy == .human, "\(error)")
    }
    #expect(StorageError.busy.nextBy == .agent)
    #expect(StorageError.locked.nextBy == .agent)
  }

  @Test func cannotOpenUsesTheFilesystemToSeparateMissingFromDenied() throws {
    try withScratchDirectory { home in
      let database = home.appending(path: "silta.db")
      let error = DatabaseError(resultCode: .SQLITE_CANTOPEN, message: "acme-private-value")
      #expect(StorageError.mapped(error, at: database.path) == .cannotOpen)
      #expect(!StorageError.mapped(error, at: database.path).message.contains("acme-private"))

      try Data("acme".utf8).write(to: database)
      try chmod(0o444, database)
      #expect(StorageError.mapped(error, at: database.path) == .accessDenied)

      try chmod(0o600, database)
      try chmod(0o555, home)
      defer { try? chmod(0o700, home) }  // restores fixture access for cleanup
      #expect(StorageError.mapped(error, at: database.path) == .accessDenied)
    }
  }

  @Test func missingDatabaseFileIsCannotOpen() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home.appending(path: "data"))
      #expect(throws: StorageError.cannotOpen) { try store.read { _ in () } }
    }
  }

  @Test func nonDatabaseFileIsCorrupt() throws {
    try withScratchDirectory { home in
      let text = String(repeating: "This is not a Silta database. ", count: 200)
      try Data(text.utf8).write(to: home.appending(path: "silta.db"))
      let store = StorageSchemaTests.store(home)
      #expect(throws: StorageError.corrupt) {
        try store.read { try Int.fetchOne($0, sql: "PRAGMA schema_version") }
      }
    }
  }

  @Test func unreadableMigrationLockIsAccessDenied() throws {
    try withScratchDirectory { home in
      do { try StorageSchemaTests.store(home).initialize() }
      let lock = home.appending(path: "migration.lock")
      try chmod(0o000, lock)
      defer { try? chmod(0o600, lock) }  // restores fixture access for cleanup
      let store = StorageSchemaTests.store(home)
      #expect(throws: StorageError.accessDenied) { try store.write { _ in () } }
    }
  }

  @Test func unwritableParentDirectoryIsAccessDenied() throws {
    try withScratchDirectory { home in
      let parent = home.appending(path: "locked")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      try chmod(0o555, parent)
      defer { try? chmod(0o700, parent) }  // restores fixture access for cleanup
      let store = StorageSchemaTests.store(parent.appending(path: "data"))
      #expect(throws: StorageError.accessDenied) { try store.write { _ in () } }
    }
  }

  @Test func readOnlyDatabaseFileIsAccessDenied() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let database = home.appending(path: "silta.db")
      try chmod(0o444, database)
      defer { try? chmod(0o600, database) }  // restores fixture access for cleanup
      #expect(throws: StorageError.accessDenied) { try store.write { _ in () } }
    }
  }

  @Test func fullDatabaseIsDiskFull() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let pages = try store.read { try Int.fetchOne($0, sql: "PRAGMA page_count") }
      try store.write {
        try $0.database.execute(sql: "PRAGMA max_page_count=\(pages ?? 0)")
      }
      #expect(throws: StorageError.diskFull) {
        try store.write { transaction in
          try transaction.database.execute(sql: "CREATE TABLE acme_fill(data BLOB)")
          try transaction.database.execute(sql: "INSERT INTO acme_fill VALUES(zeroblob(1000000))")
        }
      }
    }
  }

  @Test func missingBackupDayMetaRowIsCorrupt() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      let external = try DatabaseQueue(path: store.path)
      try external.write {
        try $0.execute(sql: "DELETE FROM meta WHERE key='last_backup_day'")
      }
      #expect(throws: StorageError.corrupt) { try store.write { _ in () } }
    }
  }

  @Test func missingWriterVersionMetaRowIsCorrupt() throws {
    try withScratchDirectory { home in
      do { try StorageSchemaTests.store(home).initialize() }
      let external = try DatabaseQueue(path: home.appending(path: "silta.db").path)
      try external.write {
        try $0.execute(sql: "DELETE FROM meta WHERE key='min_writer_version'")
      }
      let store = StorageSchemaTests.store(home)
      #expect(throws: StorageError.corrupt) { try store.initialize() }
    }
  }

  @Test func missingWorkspaceRowIsCorrupt() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      #expect(throws: StorageError.corrupt) {
        try store.write { transaction in
          _ = try WorkspaceSettings.read(workspaceID: 99, in: transaction.database)
        }
      }
    }
  }

  @Test func missingChangeSequenceIsInternalMisuse() throws {
    try withScratchDirectory { home in
      let store = StorageSchemaTests.store(home)
      try store.initialize()
      #expect(throws: StorageError.internalMisuse) {
        try store.write { transaction in
          try transaction.database.execute(sql: "DELETE FROM meta WHERE key='change_seq'")
          try transaction.recordChange(kind: "acme", rowID: 1)
        }
      }
    }
  }

  @Test func refusedWALJournalModeIsItsOwnClass() {
    #expect(throws: StorageError.walRefused) { try DatabaseStore.requireWAL("delete") }
    #expect(throws: StorageError.walRefused) { try DatabaseStore.requireWAL(nil) }
  }

  private func chmod(_ permissions: Int, _ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: permissions], ofItemAtPath: url.path)
  }
}
