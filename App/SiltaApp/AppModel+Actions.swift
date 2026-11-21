import Foundation
import SiltaAppSupport

extension AppModel {
  /// The target in the selected workspace, for reading a draft or a state.
  func target(_ ref: String) -> ActionTarget? {
    workspace.map { ActionTarget(workspace: $0, ref: ref) }
  }

  /// Runs one write for a target unless one is already running for it. Success or
  /// failure, it forces a refresh and reloads the open task before the target is free
  /// again, so a stale view (`conflict`, `not_found`, `claimed`) shows the current state
  /// and an answered question can't be answered twice from the old screen.
  @discardableResult func perform(_ write: AppWrite, for ref: String) -> Task<Void, Never>? {
    guard let writer, let target = target(ref), actions.begin(target) else { return nil }
    return Task {
      var failure: ActionFailure?
      do {
        try await writer(write, target.workspace)
      } catch {
        failure = ActionFailure(error)
      }
      await refresh(force: true).value
      await loadTaskDetail()
      if visibleData != nil { actions.selectedProposals.formIntersection(proposalRefs) }
      actions.finish(target, failure: failure)
    }
  }

  /// The task proposals My work lists, which a selection may name: the whole inbox's while
  /// it is shown, else the capped read's.
  var proposalRefs: Set<String> {
    let items = allWaiting ?? visibleData?.snapshot?.work.items ?? []
    return Set(items.filter { $0.kind == "proposal" }.flatMap(\.refs))
  }

  /// Accepts the ticked proposals among `visible` as one all-or-nothing triage, so a
  /// search never sends a ticked proposal the human can't see.
  @discardableResult func acceptSelectedProposals(among visible: [String]) -> Task<Void, Never>? {
    let refs = actions.selectedProposals.intersection(proposalRefs).intersection(visible).sorted()
    guard !refs.isEmpty else { return nil }
    return perform(.acceptProposals(refs: refs), for: Self.proposalsTarget)
  }

  /// Drops the ticked proposals among `visible` as one all-or-nothing triage. A blank
  /// reason records Core's default.
  @discardableResult func dropSelectedProposals(among visible: [String], why: String)
    -> Task<Void, Never>?
  {
    let refs = actions.selectedProposals.intersection(proposalRefs).intersection(visible).sorted()
    guard !refs.isEmpty else { return nil }
    let reason = why.trimmingCharacters(in: .whitespacesAndNewlines)
    return perform(
      .dropProposals(refs: refs, why: reason.isEmpty ? nil : reason), for: Self.proposalsTarget)
  }

  /// Unblocks a ready task under its own target, apart from the task's comment draft.
  @discardableResult func unblock(_ ref: String) -> Task<Void, Never>? {
    perform(.unblock(ref: ref), for: Self.unblockTarget(ref))
  }

  /// The one target all proposal triage shares, so only one batch runs at a time.
  static let proposalsTarget = "proposals"

  static func unblockTarget(_ ref: String) -> String { "unblock:" + ref }

  /// Sends the target's draft as an answer to a question.
  @discardableResult func answer(question: String, task: String) -> Task<Void, Never>? {
    send(draftOf: question) { .answer(task: task, question: question, body: $0) }
  }

  /// Sends the task's comment draft.
  @discardableResult func comment(task: String) -> Task<Void, Never>? {
    send(draftOf: task) { .comment(task: task, body: $0) }
  }

  /// Sends the reply draft for a thread, posted into that thread.
  @discardableResult func reply(to root: String, task: String) -> Task<Void, Never>? {
    send(draftOf: Self.replyTarget(root)) { .comment(task: task, body: $0, replyTo: root) }
  }

  /// A thread's reply draft, apart from the task's new-thread comment draft.
  static func replyTarget(_ root: String) -> String { "reply:" + root }

  private func send(draftOf ref: String, _ write: (String) -> AppWrite) -> Task<Void, Never>? {
    guard let target = target(ref) else { return nil }
    let body = actions.draft(target).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    return perform(write(body), for: ref)
  }
}
