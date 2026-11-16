import Foundation
public import SiltaCore

/// A body-free coded failure exposed without package-scoped implementation types.
public struct AppReadError: CodedError {
  /// Presentation states that cannot be selected by error code alone.
  public enum Kind: Sendable {
    /// The store cannot be opened, including a missing data folder.
    case unavailableStore
    /// A newer schema requires an updated app.
    case newerSchema
    /// Known migrations must be applied by the CLI before the viewer can read.
    case migrationRequired
    /// Other failures retain the core's explanation and recovery.
    case other
  }
  /// Typed presentation category for the viewer's store states.
  public let kind: Kind
  /// Stable core error code.
  public let code: ErrorCode
  /// Human-readable explanation.
  public let message: String
  /// Runnable recovery commands include the selected data home.
  public let next: [String]
  /// Retry delay supplied by the core, when present.
  public let retryAfter: Int?
  /// Owner of the recovery commands.
  public let nextBy: NextBy

}

extension AppReadError {
  static let migrationRequired = AppReadError(
    kind: .migrationRequired, code: .env,
    message: "Silta data needs migrations; run the matching CLI first.", next: ["silta init"],
    retryAfter: nil, nextBy: .human)

  func scoped(to home: URL) -> Self {
    Self(
      kind: kind, code: code, message: message,
      next: next.map { command in
        command == "silta" || command.hasPrefix("silta ")
          ? "SILTA_HOME=" + shellWord(home.path) + " " + command : command
      }, retryAfter: retryAfter, nextBy: nextBy)
  }

  init(_ error: any Error) {
    if let existing = error as? AppReadError {
      self = existing
      return
    }
    switch error {
    case StorageError.cannotOpen: kind = .unavailableStore
    case StorageError.schemaTooNew: kind = .newerSchema
    default: kind = .other
    }
    let coded: any CodedError = (error as? any CodedError) ?? StorageError.unknown
    code = coded.code
    message = coded.message
    next = coded.next
    retryAfter = coded.retryAfter
    nextBy = coded.nextBy
  }
}
