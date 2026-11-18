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
      actions.finish(target, failure: failure)
    }
  }

  /// Sends the target's draft as an answer to a question.
  @discardableResult func answer(question: String, task: String) -> Task<Void, Never>? {
    send(draftOf: question) { .answer(task: task, question: question, body: $0) }
  }

  /// Sends the task's comment draft.
  @discardableResult func comment(task: String) -> Task<Void, Never>? {
    send(draftOf: task) { .comment(task: task, body: $0) }
  }

  private func send(draftOf ref: String, _ write: (String) -> AppWrite) -> Task<Void, Never>? {
    guard let target = target(ref) else { return nil }
    let body = actions.draft(target).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    return perform(write(body), for: ref)
  }
}
