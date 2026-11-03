import Foundation

/// Task failures with body-free recovery commands.
package enum TaskError: CodedError, Equatable {
  /// The named task, or an entity a reference names, doesn't exist: "task AC-9",
  /// "parent task AC-9", "blocker task AC-9", "app acme-web".
  case notFound(String)

  /// A supplied value does not satisfy the command contract.
  case invalid(String)

  /// A different actor still owns the claim.
  case claimed(String, holder: String, minutes: Int)

  /// A proposal needs triage first; a human runs it, an agent asks the human.
  case proposal(String, human: Bool)

  /// The requested transition is not valid from the current status.
  case transition(String, status: String)

  /// Another writer stored a different plan revision.
  case staleRev(String, actual: Int)

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

  /// Local writes must stop after promotion to the named tracker.
  case promoted(String, external: String)

  /// Editable fields changed while input was being prepared.
  case edited(String)

  /// Work is still waiting for named prerequisites or an answer.
  case blocked(String, TaskWaiting)

  /// A blocked task must be unblocked before a tracker can take it over; `ready` says
  /// whether its block is ready to unblock.
  case blockedPromotion(String, ready: Bool)

  /// `--step` on a plan without checkboxes; the fix is a revision that has them.
  case noCheckboxes(String)

  /// `what` as a message shows it: secrets masked, control characters as spaces.
  package static func shown(_ what: String) -> String {
    SecretGuard.redacted(what).unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) ? " " : String($0)
    }.joined()
  }

  /// Maps task failures to the scripting contract.
  package var code: ErrorCode {
    switch self {
    case .blocked: .blocked
    case .promoted: .readOnlyPromoted
    case .edited: .conflict
    case .notFound: .notFound
    case .invalid, .foreignRepo, .input, .noCheckboxes: .invalid
    case .claimed: .claimed
    case .proposal, .transition, .changed, .blockedPromotion: .conflict
    case .git, .repository: .env
    case .gate: .gate
    case .staleRev: .staleRev
    }
  }

  /// Explains the failure without quoting task bodies or raw git diagnostics.
  package var message: String {
    switch self {
    case .blocked(let ref, let waiting):
      "\(ref) is blocked, waiting on \(waiting.on.isEmpty ? "an answer" : waiting.on.joined(separator: ", ")) for \(waiting.ageDays) d."
        + (waiting.dropped.isEmpty ? "" : " Blocker dropped: re-plan.")
    case .promoted(let ref, let external): "\(ref) is read-only; work in tracker \(external)."
    case .blockedPromotion(let ref, _): "\(ref) is blocked; unblock it before promoting it."
    case .edited: "Task fields changed during editing; re-read before applying an edit."
    case .notFound(let what):
      Self.shown(what.prefix(1).uppercased() + what.dropFirst()) + " not found."
    case .invalid(let reason): reason
    case .noCheckboxes(let ref):
      "\(ref)'s plan has 0 checkboxes; --step N counts top-level `- [ ] …` lines, "
        + "so store a revision with them."
    case .claimed(let ref, let holder, let minutes):
      "\(ref) is claimed by \(holder) (\(minutes) min old); pick other work, "
        + "or ask the human before stealing it."
    case .proposal(let ref, let human):
      human
        ? "Proposal \(ref) needs triage first."
        : "Proposal \(ref) needs human triage; ask in chat before accepting it."
    case .transition(let ref, let status): "\(ref) cannot make this transition from \(status)."
    case .repository:
      "Task repository is not registered locally or its .git marker is missing; "
        + "ask a human to restore or register it with init --scan."
    case .input: "Could not read the UTF-8 body file; check its path and permissions."
    case .git: "Git could not report the task's worktree or commit; ask a human to check git."
    case .foreignRepo: "Use a worktree and commit from the task's registered repository."
    case .gate: "A human approval is required; ask a human to approve or use done --force."
    case .staleRev(let ref, let actual):
      "\(ref) has plan revision \(actual); re-read before replacing it."
    case .changed: "Task repository information changed; re-read before retrying."
    }
  }

  /// Names only implemented, body-free commands.
  package var next: [String] {
    switch self {
    case .blocked(let ref, let waiting):
      waiting.ready ? ["silta task unblock \(ref)"] : ["silta task ls --status todo"]
    case .promoted, .claimed: ["silta task ls --status todo"]
    case .edited(let ref): ["silta task show \(ref)"]
    case .proposal(let ref, let human):
      ["silta task triage --accept \(ref)" + (human ? "" : " --approved \"<the human's words>\"")]
    case .blockedPromotion(let ref, let ready):
      [ready ? "silta task unblock \(ref)" : "silta task show \(ref)"]
    case .transition(let ref, _), .gate(let ref), .staleRev(let ref, _):
      ["silta task show \(ref)"]
    case .changed(let ref): ref.map { ["silta task show \($0)"] } ?? ["silta task ls"]
    case .notFound: ["silta task ls"]
    case .noCheckboxes(let ref): ["silta task plan \(ref) -F -"]
    case .invalid, .foreignRepo, .input: ["silta task add --help"]
    case .repository: ["silta init --help"]
    case .git: ["silta doctor"]
    }
  }

  /// An agent's proposal refusal needs the human's words for triage; every other case
  /// follows its code.
  package var nextBy: NextBy {
    if case .proposal(_, human: false) = self { .human } else { code.nextBy }
  }
}
