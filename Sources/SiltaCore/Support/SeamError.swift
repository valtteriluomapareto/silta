/// Invalid seam inputs and operational failures reported at the command boundary.
package enum SeamError: CodedError, CaseIterable {
  /// The data-directory path cannot be resolved safely.
  case invalidHome
  /// The fixed clock value is not canonical UTC with milliseconds on or after 1970.
  case invalidNow
  /// The seeded generator value is not an unsigned decimal integer.
  case invalidIDSeed
  /// The supplied instant cannot be represented by a ULID.
  case invalidTimestamp
  /// The absolute git executable cannot be started.
  case gitUnavailable
  /// Temporary output files cannot be created, opened or read.
  case gitCapture

  /// Invalid configuration is caller-correctable; git operational failures need a human.
  package var code: ErrorCode {
    switch self {
    case .gitUnavailable, .gitCapture: .env
    default: .invalid
    }
  }

  /// Names the invalid input or the failed operation without exposing captured content.
  package var message: String {
    switch self {
    case .invalidHome: "SILTA_HOME must be an absolute, resolvable directory path."
    case .invalidNow:
      "SILTA_NOW must be UTC in YYYY-MM-DDTHH:mm:ss.SSSZ format on or after 1970-01-01."
    case .invalidIDSeed: "SILTA_ID_SEED must be an unsigned 64-bit decimal integer."
    case .invalidTimestamp: "Clock timestamp must fit the unsigned 48-bit ULID millisecond range."
    case .gitUnavailable: "Git could not be started; check the configured absolute git path."
    case .gitCapture: "Git output could not be captured."
    }
  }

  /// Recovery commands for the caller or human, as selected by the error code.
  package var next: [String] {
    switch self {
    case .invalidHome: ["printf '%s\\n' \"$SILTA_HOME\"", "silta --help"]
    case .invalidNow: ["unset SILTA_NOW", "silta --help"]
    case .invalidIDSeed: ["unset SILTA_ID_SEED", "silta --help"]
    case .invalidTimestamp: ["unset SILTA_NOW", "silta doctor"]
    case .gitUnavailable: ["/usr/bin/git --version", "silta doctor"]
    case .gitCapture: ["silta doctor"]
    }
  }
}
