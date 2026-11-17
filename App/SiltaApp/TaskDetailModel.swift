import Observation
import SiltaAppSupport

@MainActor @Observable
final class TaskDetailModel {
  private(set) var value: AppTask?
  private(set) var failure: String?
  private(set) var isLoading = false
  private var generation = 0

  func clear() {
    generation += 1
    value = nil
    failure = nil
    isLoading = false
  }

  func load(read: @MainActor () async throws -> AppTask) async {
    clear()
    let token = generation
    isLoading = true
    do {
      let result = try await read()
      guard token == generation, !Task.isCancelled else { return }
      value = result
    } catch {
      guard token == generation, !Task.isCancelled else { return }
      failure = AppLoadFailure(error).message
    }
    if token == generation { isLoading = false }
  }
}
