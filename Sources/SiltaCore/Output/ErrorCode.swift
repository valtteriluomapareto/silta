/// Who should run an error's `next` commands (spec §16).
package enum NextBy: String, Sendable {
  /// The calling agent can run them itself.
  case agent
  /// Only the human can; an agent should stop and ask.
  case human
}

/// The error-code table (spec §16): every error Silta reports carries one of these
/// codes, and the code alone decides the process exit status.
public enum ErrorCode: String, CaseIterable, Sendable {
  /// The call doesn't parse.
  case usage
  /// The call parses, but a value is out of range or inconsistent.
  case invalid
  /// The referenced task, comment, app or ref doesn't exist.
  case notFound = "not_found"
  /// The repo or workspace isn't registered with Silta.
  case unregistered
  /// Only a human may do this.
  case humanOnly = "human_only"
  /// The task was promoted to a tracker and is read-only here.
  case readOnlyPromoted = "read_only_promoted"
  /// Silta can't tell which app the working directory belongs to.
  case ambiguousLocation = "ambiguous_location"
  /// The database stayed locked through every retry.
  case busy
  /// The write conflicts with the current state.
  case conflict
  /// Someone else holds the claim.
  case claimed
  /// The revision the caller read is no longer current.
  case staleRev = "stale_rev"
  /// Someone else holds the lease.
  case leaseTaken = "lease_taken"
  /// A review gate isn't met.
  case gate
  /// Too many writes in a short time.
  case rateLimited = "rate_limited"
  /// The environment is broken: schema too new, read-only DB, git missing, no network,
  /// or a bug in Silta.
  case env

  /// The process exit status for this code.
  package var exitCode: Int32 {
    switch self {
    case .usage, .invalid: 1
    case .notFound, .unregistered: 2
    case .humanOnly, .readOnlyPromoted: 3
    case .ambiguousLocation: 4
    case .busy: 5
    case .conflict, .claimed, .staleRev, .leaseTaken: 6
    case .gate: 7
    case .rateLimited: 8
    case .env: 9
    }
  }

  /// Who should run the `next` commands of an error with this code.
  package var nextBy: NextBy {
    switch self {
    case .humanOnly, .readOnlyPromoted, .env: .human
    default: .agent
    }
  }

  /// What an agent should do on this code: the "Agent should" column of spec §16.
  package var agentShould: String {
    switch self {
    case .usage, .invalid: "Read `silta <cmd> --help` and fix the call"
    case .notFound, .unregistered: "Check the ref, or carry on without silta"
    case .humanOnly, .readOnlyPromoted: "Stop; ask the human to run the printed command"
    case .ambiguousLocation: "Retry with `--app <slug>` from the candidates"
    case .busy: "Retry once after a few seconds"
    case .conflict, .claimed, .staleRev, .leaseTaken: "Re-read, then decide; don't steal"
    case .gate: "Request a review or ask the human"
    case .rateLimited: "Wait for `retry_after_s`, or summarise"
    case .env: "Report the printed fix to the human"
    }
  }
}
