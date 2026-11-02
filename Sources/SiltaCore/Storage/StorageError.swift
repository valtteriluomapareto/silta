import GRDB

/// Storage failures that retain no SQL, bound values or underlying error objects.
package enum StorageError: CodedError, CaseIterable {
  /// SQLite remained busy through the permitted attempts.
  case busy
  /// The database could not be opened, read or written.
  case unavailable
  /// The database requires a newer binary or contains unknown migrations.
  case schemaTooNew
  /// A required complete backup could not be created or installed.
  case backupFailed

  /// Busy is retryable; other storage failures require human repair.
  package var code: ErrorCode {
    self == .busy ? .busy : .env
  }

  /// A body-free explanation and safe recovery instruction.
  package var message: String {
    switch self {
    case .busy: "Database is busy; retry the original invocation once after retry_after_s."
    case .unavailable: "Database is unavailable or read-only."
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
    self == .busy ? 5 : nil
  }

  /// Maps operational errors without retaining their SQL or potentially private messages.
  package static func mapped(_ error: any Error) -> StorageError {
    if let error = error as? StorageError { return error }
    if let error = error as? DatabaseError, error.resultCode == .SQLITE_BUSY { return .busy }
    return .unavailable
  }
}
