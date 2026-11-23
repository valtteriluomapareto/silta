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
    guard let running = send(write, for: ref) else { return nil }
    return Task { _ = await running.value }
  }

  /// `perform`, handing back what the writer returned: a created task's reference.
  private func send(_ write: AppWrite, for ref: String) -> Task<String?, Never>? {
    guard let writer, let target = target(ref), actions.begin(target) else { return nil }
    return Task {
      var failure: ActionFailure?
      var result: String?
      do {
        result = try await writer(write, target.workspace)
      } catch {
        failure = ActionFailure(error)
      }
      await refresh(force: true).value
      await loadTaskDetail()
      if visibleData != nil { actions.selectedProposals.formIntersection(proposalRefs) }
      actions.finish(target, failure: failure)
      return result
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

  /// Drops the ticked proposals among `visible` as one all-or-nothing triage, with the
  /// drop reason draft; a blank reason records Core's default. The reason clears, and the
  /// reason field closes, only when the drop succeeds.
  @discardableResult func dropSelectedProposals(among visible: [String]) -> Task<Void, Never>? {
    let refs = actions.selectedProposals.intersection(proposalRefs).intersection(visible).sorted()
    guard !refs.isEmpty, let reasonTarget = target(Self.dropReasonTarget) else { return nil }
    let reason = actions.draft(reasonTarget).trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let running = perform(
        .dropProposals(refs: refs, why: reason.isEmpty ? nil : reason), for: Self.proposalsTarget)
    else { return nil }
    return Task {
      await running.value
      guard let proposals = target(Self.proposalsTarget), actions.failures[proposals] == nil
      else { return }
      actions.setDraft("", for: reasonTarget)
      droppingProposals = false
    }
  }

  /// The drop reason's draft, apart from the proposals' shared write target.
  static let dropReasonTarget = "drop-reason"

  /// Unblocks a ready task under its own target, apart from the task's comment draft.
  @discardableResult func unblock(_ ref: String) -> Task<Void, Never>? {
    perform(.unblock(ref: ref), for: Self.unblockTarget(ref))
  }

  /// Moves a blocked task's follow-up ahead under its follow-up target.
  @discardableResult func snooze(_ ref: String, days: Int) -> Task<Void, Never>? {
    perform(.snooze(ref: ref, days: days), for: Self.followUpTarget(ref))
  }

  /// Returns a blocked task to todo even with open blockers; the view confirms first.
  @discardableResult func unblockAnyway(_ ref: String, confirmed: [String])
    -> Task<Void, Never>?
  {
    perform(.unblockAnyway(ref: ref, confirmed: confirmed), for: Self.followUpTarget(ref))
  }

  /// Drops a blocked task with its drop reason draft, which clears only on success.
  @discardableResult func dropTask(_ ref: String) -> Task<Void, Never>? {
    guard let reasonTarget = target(Self.dropTaskReasonTarget(ref)) else { return nil }
    let reason = actions.draft(reasonTarget).trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let running = perform(
        .dropTask(ref: ref, why: reason.isEmpty ? nil : reason), for: Self.followUpTarget(ref))
    else { return nil }
    return Task {
      await running.value
      guard let followUp = target(Self.followUpTarget(ref)), actions.failures[followUp] == nil
      else { return }
      actions.setDraft("", for: reasonTarget)
    }
  }

  /// One write at a time per blocked task: snooze, unblock anyway or drop.
  static func followUpTarget(_ ref: String) -> String { "followup:" + ref }

  static func dropTaskReasonTarget(_ ref: String) -> String { "drop-task:" + ref }

  /// The one target all proposal triage shares, so only one batch runs at a time.
  static let proposalsTarget = "proposals"

  static func unblockTarget(_ ref: String) -> String { "unblock:" + ref }

  /// Sends the target's draft as an answer to a question.
  @discardableResult func answer(question: String, task: String) -> Task<Void, Never>? {
    send(draftOf: question) { .answer(task: task, question: question, body: $0) }
  }

  /// What a new thread on a task is: a plain comment, a decision agents see in their
  /// briefs, or a question to one agent session.
  enum CommentKind: String, CaseIterable {
    case comment, decision, question
  }

  /// Sends the task's comment draft as `kind`; a question needs its recipient.
  @discardableResult func comment(
    task: String, kind: CommentKind = .comment, to recipient: String? = nil
  ) -> Task<Void, Never>? {
    if kind == .question, recipient?.isEmpty != false { return nil }
    return send(draftOf: task) {
      .comment(
        task: task, body: $0, kind: kind.rawValue, to: kind == .question ? [recipient ?? ""] : [])
    }
  }

  /// Creates a todo task. With `copyPrompt`, copies the prompt that hands it to an agent once
  /// Core has created it; the app launches nothing.
  @discardableResult func createTask(_ task: AppNewTask, copyPrompt: Bool) -> Task<Void, Never>? {
    guard let workspace, let running = send(.createTask(task), for: Self.newTaskTarget)
    else { return nil }
    let name = workspaceName ?? workspace
    return Task {
      guard let ref = await running.value else { return }
      var prompt: String?
      if copyPrompt, let reader {
        let text = reader.agentPrompt(task: ref, workspace: workspace, name: name)
        if pasteboard(text) { prompt = text }
      }
      createdPrompt = prompt
      createdTask = ref
    }
  }

  /// The New Task sheet's own target, so one create runs at a time.
  static let newTaskTarget = "new-task"

  /// Resolves a thread under its own target.
  @discardableResult func resolve(thread ref: String) -> Task<Void, Never>? {
    perform(.resolveThreads(refs: [ref]), for: Self.resolveTarget(ref))
  }

  /// Reopens a resolved thread under the same target as resolving it.
  @discardableResult func reopen(thread ref: String) -> Task<Void, Never>? {
    perform(.reopenThreads(refs: [ref]), for: Self.resolveTarget(ref))
  }

  static func resolveTarget(_ ref: String) -> String { "resolve:" + ref }

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
