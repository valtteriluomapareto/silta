import Foundation
import GRDB

/// Storage failures that retain no SQL, bound values or underlying error objects.
package enum StorageError: CodedError, CaseIterable {
  /// SQLite remained busy through the permitted attempts.
  case busy
  /// Another connection or process holds a lock SQLite cannot wait out.
  case locked
  /// The database file or its directory denies the read or write Silta needs.
  case accessDenied
  /// The database file is missing or cannot be opened.
  case cannotOpen
  /// The filesystem reported an I/O failure while reading or writing the database.
  case ioFailure
  /// The database's filesystem is out of space or over its quota.
  case diskFull
  /// The database file could not be switched to WAL journal mode.
  case walRefused
  /// SQLite reports corruption, or a stored value or reference cannot be read.
  case corrupt
  /// The database engine ran out of memory or exceeded a value size limit.
  case resourceExhausted
  /// Silta made a database call its own schema does not allow.
  case internalMisuse
  /// A storage failure outside the classes above.
  case unknown
  /// A write violated a database constraint, so Silta generated conflicting state.
  case constraintViolation
  /// The database requires a newer binary or contains unknown migrations.
  case schemaTooNew
  /// A required complete backup could not be created or installed.
  case backupFailed

  /// The locked classes are retryable; the rest need their printed recovery.
  package var code: ErrorCode {
    switch self {
    case .busy, .locked: .busy
    default: .env
    }
  }

  /// A body-free explanation and safe recovery instruction.
  package var message: String {
    switch self {
    case .busy: "Database is busy; retry the original invocation once after retry_after_s."
    case .locked:
      "Database is locked by another connection; retry the original invocation once after "
        + "retry_after_s."
    case .accessDenied:
      "Database access is denied by file permissions or a read-only file or directory."
    case .cannotOpen:
      "Database file could not be opened; it may be missing or its directory may not exist."
    case .ioFailure: "Database file could not be read or written because of a filesystem I/O error."
    case .diskFull: "Database write failed because the disk is full or over its quota."
    case .walRefused:
      "Database could not be switched to WAL journal mode; its filesystem may not support it."
    case .corrupt:
      "Database is corrupt: SQLite reported corruption or a stored value or reference cannot be "
        + "read."
    case .resourceExhausted:
      "Database engine ran out of memory or a value exceeded SQLite's size limit."
    case .internalMisuse:
      "internal error (bug): Silta made an invalid database call; nothing was saved. "
        + "Report which silta command failed (not its arguments) and the time, "
        + "with silta doctor output."
    case .unknown: "Storage failed for an unrecognized reason."
    case .constraintViolation:
      "internal error (bug): a write conflicted with existing data; nothing was saved. "
        + "Report which silta command failed (not its arguments) and the time, "
        + "with silta doctor output."
    case .schemaTooNew: "Database requires a newer version of silta."
    case .backupFailed: "Required database backup could not be completed."
    }
  }

  /// Fixed safe diagnostics; command arguments are never reconstructed or retained.
  package var next: [String] {
    self == .schemaTooNew ? ["update silta"] : ["silta doctor"]
  }

  /// Suggested delay after the bounded busy attempts are exhausted.
  package var retryAfter: Int? {
    switch self {
    case .busy, .locked: 5
    default: nil
    }
  }

  /// Maps operational errors without retaining their SQL or potentially private messages.
  package static func mapped(_ error: any Error, at path: String? = nil) -> StorageError {
    if let error = error as? StorageError { return error }
    if let error = error as? DatabaseError { return mapped(error, at: path) }
    if let error = error as? CocoaError { return mapped(error) }
    if let error = error as? POSIXError { return mapped(error.code) }
    return .unknown
  }

  /// Maps a failed file call's `errno` without retaining its message.
  package static func fileFailure(_ code: Int32, at path: String) -> StorageError {
    guard let posix = POSIXErrorCode(rawValue: code) else { return .ioFailure }
    return mapped(POSIXError(posix), at: path)
  }

  /// The SQLite primary code decides the class; a few extended codes override it.
  private static func mapped(_ error: DatabaseError, at path: String?) -> StorageError {
    switch error.extendedResultCode {
    case .SQLITE_IOERR_ACCESS, .SQLITE_IOERR_AUTH: return .accessDenied
    case .SQLITE_IOERR_NOMEM: return .resourceExhausted
    default: return mapped(error.resultCode, at: path)
    }
  }

  private static func mapped(_ code: ResultCode, at path: String?) -> StorageError {
    switch code {
    case .SQLITE_BUSY: return .busy
    case .SQLITE_LOCKED, .SQLITE_PROTOCOL: return .locked
    case .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_AUTH: return .accessDenied
    case .SQLITE_CANTOPEN: return cannotOpen(at: path)
    case .SQLITE_IOERR, .SQLITE_NOLFS: return .ioFailure
    case .SQLITE_FULL: return .diskFull
    case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_FORMAT: return .corrupt
    case .SQLITE_NOMEM, .SQLITE_TOOBIG: return .resourceExhausted
    case .SQLITE_CONSTRAINT: return .constraintViolation
    default: return isMisuse(code) ? .internalMisuse : .unknown
    }
  }

  /// Calls Silta's own schema and bindings cannot produce, so they are bugs, not environment.
  private static func isMisuse(_ code: ResultCode) -> Bool {
    [
      ResultCode.SQLITE_ERROR, .SQLITE_INTERNAL, .SQLITE_ABORT, .SQLITE_INTERRUPT, .SQLITE_SCHEMA,
      .SQLITE_MISMATCH, .SQLITE_MISUSE, .SQLITE_RANGE, .SQLITE_NOTFOUND,
    ].contains(code)
  }

  /// SQLite reports one code for a missing file and a denied one; the filesystem separates them.
  private static func cannotOpen(at path: String?) -> StorageError {
    guard let path else { return .cannotOpen }
    let manager = FileManager.default
    guard manager.fileExists(atPath: path) else { return .cannotOpen }
    let directory = URL(filePath: path).deletingLastPathComponent().path
    let writable =
      manager.isWritableFile(atPath: path) && manager.isWritableFile(atPath: directory)
    return manager.isReadableFile(atPath: path) && writable ? .cannotOpen : .accessDenied
  }

  /// File-manager failures arrive as Cocoa errors, not POSIX ones.
  private static func mapped(_ error: CocoaError) -> StorageError {
    switch error.code {
    case .fileWriteOutOfSpace: return .diskFull
    case .fileWriteNoPermission, .fileReadNoPermission: return .accessDenied
    case .fileNoSuchFile: return .cannotOpen
    case .fileLocking: return .locked
    case .fileReadCorruptFile: return .corrupt
    default: return .ioFailure
    }
  }

  /// Raw `errno` values from `open`, `flock` and similar file calls.
  private static func mapped(_ code: POSIXErrorCode) -> StorageError {
    switch code {
    case .EACCES, .EPERM, .EROFS: return .accessDenied
    case .ENOSPC, .EDQUOT: return .diskFull
    case .ENOENT, .ENOTDIR, .EISDIR: return .cannotOpen
    case .ENOLCK, .EAGAIN: return .locked
    case .EMFILE, .ENFILE, .ENOMEM: return .resourceExhausted
    default: return .ioFailure
    }
  }
}
