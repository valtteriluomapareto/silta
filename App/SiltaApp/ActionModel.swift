import Foundation
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
/// its write succeeds. With defaults, drafts outlast a quit; automated runs pass none.
@MainActor @Observable
final class ActionModel {
  private var drafts: [ActionTarget: String] = [:] {
    didSet { store() }
  }
  private(set) var sending: Set<ActionTarget> = []
  private(set) var failures: [ActionTarget: ActionFailure] = [:]
  /// Task proposals ticked in My work; none at first.
  var selectedProposals: Set<String> = []

  @ObservationIgnored private let defaults: UserDefaults?
  static let draftsKey = "unsentDrafts"
  /// Separates the workspace and the ref in a stored key; neither can contain it.
  private static let separator: Character = "\u{1F}"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults
    let stored = defaults?.dictionary(forKey: Self.draftsKey) as? [String: String] ?? [:]
    drafts = Dictionary(
      uniqueKeysWithValues: stored.compactMap { key, text in
        let parts = key.split(separator: Self.separator, maxSplits: 1).map(String.init)
        return parts.count == 2 ? (ActionTarget(workspace: parts[0], ref: parts[1]), text) : nil
      })
  }

  /// Stores the drafts, leaving out any that look like a secret: Core refuses those on
  /// send, and they shouldn't outlive the app in a preferences file.
  private func store() {
    guard let defaults else { return }
    let stored = Dictionary(
      uniqueKeysWithValues: drafts.filter { !AppSecrets.contains($0.value) }.map {
        ($0.key.workspace + String(Self.separator) + $0.key.ref, $0.value)
      })
    if stored.isEmpty {
      defaults.removeObject(forKey: Self.draftsKey)
    } else {
      defaults.set(stored, forKey: Self.draftsKey)
    }
  }

  func draft(_ target: ActionTarget) -> String { drafts[target] ?? "" }

  func setDraft(_ text: String, for target: ActionTarget) {
    drafts[target] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
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
