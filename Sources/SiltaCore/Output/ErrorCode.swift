/// Who must act before an error's `next` commands can run (spec §16).
public enum NextBy: String, Sendable {
  /// The calling agent can run them itself.
  case agent
  /// The agent must ask the human in chat before acting.
  case human
}

/// The error-code table (spec §16): every error Silta reports carries one of these
/// codes, and the code alone decides the process exit status.
public enum ErrorCode: String, CaseIterable, Sendable, Encodable {
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
  /// Work is waiting for prerequisites or an answer.
  case blocked
  /// A review gate isn't met.
  case gate
  /// Too many writes in a short time.
  case rateLimited = "rate_limited"
  /// The environment is broken: a corrupt, read-only, missing, full or otherwise failed
  /// database, schema too new, git missing, no network, or a bug in Silta.
  case env

  /// The process exit status for this code.
  package var exitCode: Int32 {
    switch self {
    case .usage, .invalid: 1
    case .notFound, .unregistered: 2
    case .humanOnly, .readOnlyPromoted: 3
    case .ambiguousLocation: 4
    case .busy: 5
    case .conflict, .claimed, .staleRev, .leaseTaken, .blocked: 6
    case .gate: 7
    case .rateLimited: 8
    case .env: 9
    }
  }

  /// Who must act before the `next` commands of an error with this code can run.
  package var nextBy: NextBy {
    switch self {
    case .humanOnly, .env: .human
    default: .agent
    }
  }

  /// A shared guide/schema row with the code's default recovery actor and advice.
  package var helpLine: String {
    "\(rawValue)  exit \(exitCode), next by \(nextBy.rawValue): \(agentShould)"
  }

  /// What an agent should do on this code: the "Agent should" column of spec §16.
  package var agentShould: String {
    switch self {
    case .usage, .invalid: "Read `silta <cmd> --help` and fix the call"
    case .notFound, .unregistered: "Check the ref, or carry on without silta"
    case .humanOnly:
      "Stop and ask the human in chat; rerun with `--approved \"<their words>\"` after they say yes"
    case .readOnlyPromoted: "Leave it to its tracker and pick other work"
    case .ambiguousLocation: "Retry with `--app <slug>` from the candidates"
    case .busy: "Retry once after a few seconds"
    case .conflict, .claimed, .staleRev, .leaseTaken, .blocked:
      "Re-read, then decide; don't steal, and don't unblock while blockers are open"
    case .gate: "Request a review or ask the human"
    case .rateLimited: "Wait for `retry_after_s`, or summarise"
    case .env: "Report the printed fix to the human"
    }
  }
}
