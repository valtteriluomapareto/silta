import SiltaCore

/// A body-free coded failure exposed without package-scoped implementation types.
public struct AppReadError: Error, Sendable {
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
  public let code: String
  /// Human-readable explanation.
  public let message: String
  /// Suggested recovery commands.
  public let next: [String]

  init(_ error: any Error) {
    switch error {
    case StorageError.cannotOpen: kind = .unavailableStore
    case StorageError.schemaTooNew: kind = .newerSchema
    default: kind = .other
    }
    let coded: any CodedError = (error as? any CodedError) ?? StorageError.unknown
    code = coded.code.rawValue
    message = coded.message
    next = coded.next
  }
}
