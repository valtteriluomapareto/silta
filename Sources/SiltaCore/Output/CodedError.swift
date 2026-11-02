/// An error Silta reports to its caller: a code from the spec §16 table, a one-line
/// message, and the commands to run next. Each area defines its own conforming enum
/// (D22).
public protocol CodedError: Error, Sendable {  // guard:allow-error the root error type
  /// The table code; it decides the exit status.
  var code: ErrorCode { get }
  /// What happened, on one line, written for an agent.
  var message: String { get }
  /// The commands to run next; never empty.
  var next: [String] { get }
  /// Seconds to wait before retrying, for `rate_limited` and `busy`.
  var retryAfter: Int? { get }
}

extension CodedError {
  /// No retry delay unless the error sets one.
  public var retryAfter: Int? { nil }

  /// The process exit status, derived from `code` so the two can't disagree.
  package var exitCode: Int32 { code.exitCode }
}
