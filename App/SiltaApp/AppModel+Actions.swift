import Foundation
import SiltaAppSupport

extension AppModel {
  /// The target in the selected workspace, for reading a draft or a state.
  func target(_ ref: String) -> ActionTarget? {
    workspace.map { ActionTarget(workspace: $0, ref: ref) }
  }

  /// Runs one write for a target unless one is already running for it. Success or
  /// failure, it then forces a refresh and reloads the open task, so a stale view
  /// (`conflict`, `not_found`, `claimed`) shows the current state.
  @discardableResult func perform(_ write: AppWrite, for ref: String) -> Task<Void, Never>? {
    guard let writer, let target = target(ref), actions.begin(target) else { return nil }
    return Task {
      var failure: ActionFailure?
      do {
        try await writer(write, target.workspace)
      } catch {
        failure = ActionFailure(error)
      }
      actions.finish(target, failure: failure)
      await refresh(force: true).value
      await loadTaskDetail()
    }
  }

  /// Sends the target's draft as an answer to a question.
  @discardableResult func answer(question: String, task: String) -> Task<Void, Never>? {
    guard let target = target(question) else { return nil }
    let body = actions.draft(target).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    return perform(.answer(task: task, question: question, body: body), for: question)
  }

  /// Sends the task's comment draft.
  @discardableResult func comment(task: String) -> Task<Void, Never>? {
    guard let target = target(task) else { return nil }
    let body = actions.draft(target).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    return perform(.comment(task: task, body: body), for: task)
  }
}
