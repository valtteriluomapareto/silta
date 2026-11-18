import Observation
import SiltaAppSupport

/// What one write acts on: the question ref for an answer, the task ref for a comment,
/// the answer ref for accepting it. My work and the inspector share a target, so they
/// share its draft and its in-flight guard.
nonisolated struct ActionTarget: Hashable, Sendable {
  let workspace: String
  let ref: String
}

/// A refused write as the card shows it: Core's code, message and recovery commands.
nonisolated struct ActionFailure: Equatable, Sendable {
  let code: String?
  let message: String
  let commands: [String]

  init(_ error: any Error) {
    if let failure = error as? AppReadError {
      code = failure.codeName
      message = failure.message
      commands = failure.next
    } else {
      code = nil
      message = "Couldn’t save to Silta."
      commands = []
    }
  }
}

/// Drafts, in-flight writes and failures, keyed by target. A draft clears only when
/// its write succeeds.
@MainActor @Observable
final class ActionModel {
  private var drafts: [ActionTarget: String] = [:]
  private(set) var sending: Set<ActionTarget> = []
  private(set) var failures: [ActionTarget: ActionFailure] = [:]

  func draft(_ target: ActionTarget) -> String { drafts[target] ?? "" }

  func setDraft(_ text: String, for target: ActionTarget) {
    drafts[target] = text.isEmpty ? nil : text
  }

  func isSending(_ target: ActionTarget) -> Bool { sending.contains(target) }

  /// Starts a write unless one is already running for the target.
  func begin(_ target: ActionTarget) -> Bool {
    guard !sending.contains(target) else { return false }
    sending.insert(target)
    failures[target] = nil
    return true
  }

  func finish(_ target: ActionTarget, failure: ActionFailure?) {
    sending.remove(target)
    failures[target] = failure
    if failure == nil { drafts[target] = nil }
  }
}
