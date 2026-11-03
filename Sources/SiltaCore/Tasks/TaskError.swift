/// Task failures with body-free recovery commands.
package enum TaskError: CodedError, Equatable {
  /// The task or an explicitly named workspace entity does not exist.
  case notFound

  /// A supplied value does not satisfy the command contract.
  case invalid(String)

  /// A different actor still owns the claim.
  case claimed(String, holder: String, minutes: Int)

  /// An agent proposal needs human triage.
  case proposal(String)

  /// The requested transition is not valid from the current status.
  case transition(String, status: String)

  /// Git could not provide commit or worktree information.
  case git

  /// The local repository binding needs human repair.
  case repository

  /// A body file could not be read as UTF-8.
  case input

  /// The current worktree or requested commit belongs to another repository.
  case foreignRepo

  /// A configured review gate has not been met.
  case gate(String)

  /// Git attribution became stale before the write.
  case changed(String?)

  /// Maps task failures to the scripting contract.
  package var code: ErrorCode {
    switch self {
    case .notFound: .notFound
    case .invalid, .foreignRepo: .invalid
    case .claimed: .claimed
    case .proposal, .transition, .changed: .conflict
    case .git, .input, .repository: .env
    case .gate: .gate
    }
  }

  /// Explains the failure without quoting task bodies or raw git diagnostics.
  package var message: String {
    switch self {
    case .notFound: "Task or workspace entity not found."
    case .invalid(let reason): reason
    case .claimed(let ref, let holder, let minutes):
      "\(ref) is claimed by \(holder) (\(minutes) min old); do not steal."
    case .proposal(let ref):
      "Proposal \(ref) needs human triage; choose todo work meanwhile."
    case .transition(let ref, let status): "\(ref) cannot make this transition from \(status)."
    case .repository:
      "Task repository is not registered locally or its .git marker is missing; "
        + "ask a human to restore or register it with init --scan."
    case .input: "Could not read the UTF-8 body file; check its path and permissions."
    case .git: "Git could not report the task's worktree or commit; ask a human to check git."
    case .foreignRepo: "Use a worktree and commit from the task's registered repository."
    case .gate: "A human approval is required; ask a human to approve or use done --force."
    case .changed: "Task repository information changed; re-read before retrying."
    }
  }

  /// Names only implemented, body-free commands.
  package var next: [String] {
    switch self {
    case .proposal: ["silta task ls --status todo"]
    case .claimed(let ref, _, _), .transition(let ref, _), .gate(let ref):
      ["silta task show \(ref)"]
    case .changed(let ref): ref.map { ["silta task show \($0)"] } ?? ["silta task ls"]
    case .notFound: ["silta task ls"]
    case .invalid, .foreignRepo: ["silta task add --help"]
    case .repository: ["silta init --help"]
    case .git, .input: ["silta doctor"]
    }
  }
}
