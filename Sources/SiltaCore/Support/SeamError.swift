/// Bad `SILTA_*` configuration and git failures reported at the command boundary.
/// The harness or the human sets these variables, and an agent's shell may not keep an
/// `unset` between calls, so every case is `env`: report it to the human (D34).
package enum SeamError: CodedError, CaseIterable {
  /// The data-directory path cannot be resolved safely.
  case invalidHome
  /// The fixed clock value is not canonical UTC with milliseconds on or after 1970.
  case invalidNow
  /// The seeded generator value is not an unsigned decimal integer.
  case invalidIDSeed
  /// The supplied instant cannot be represented by a ULID.
  case invalidTimestamp
  /// `SILTA_ACTOR` is not `human:<name>`, `agent:<tool>` or `agent:<tool>:<session>`.
  case invalidActor
  /// `SILTA_SESSION` has characters an actor can't record.
  case invalidSession
  /// The absolute git executable cannot be started.
  case gitUnavailable
  /// Temporary output files cannot be created, opened or read.
  case gitCapture

  /// The fix belongs to whoever launches silta.
  package var code: ErrorCode {
    .env
  }

  /// Names the variable and the form it takes, without echoing its value.
  package var message: String {
    switch self {
    case .invalidHome:
      "SILTA_HOME must be an absolute path to a directory; fix it where silta is launched."
    case .invalidNow:
      "SILTA_NOW must be UTC in YYYY-MM-DDTHH:mm:ss.SSSZ format on or after 1970-01-01."
    case .invalidIDSeed: "SILTA_ID_SEED must be an unsigned 64-bit decimal integer."
    case .invalidTimestamp: "SILTA_NOW is outside the range a ULID timestamp can hold."
    case .invalidActor:
      "SILTA_ACTOR must be human:<name>, agent:<tool> or agent:<tool>:<session>, "
        + "each part 1 to 64 letters, digits or . _ - @ +."
    case .invalidSession: "SILTA_SESSION must be 1 to 64 letters, digits or . _ - @ +."
    case .gitUnavailable: "Git could not be started; check the configured absolute git path."
    case .gitCapture: "Git output could not be captured."
    }
  }

  /// What the human can run to inspect or clear the setting.
  package var next: [String] {
    switch self {
    case .invalidHome: ["printf '%s\\n' \"$SILTA_HOME\""]
    case .invalidNow, .invalidTimestamp: ["unset SILTA_NOW"]
    case .invalidIDSeed: ["unset SILTA_ID_SEED"]
    case .invalidActor: ["unset SILTA_ACTOR"]
    case .invalidSession: ["unset SILTA_SESSION"]
    case .gitUnavailable: ["/usr/bin/git --version", "silta doctor"]
    case .gitCapture: ["silta doctor"]
    }
  }
}
