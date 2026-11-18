import Observation
import SiltaAppSupport

@MainActor @Observable
final class TaskDetailModel {
  private(set) var value: AppTask?
  private(set) var failure: String?
  private(set) var isLoading = false
  private var generation = 0
  private var workspace: String?
  private var ref: String?
  private var loadedVersion: Int?

  func clear() {
    generation += 1
    workspace = nil
    ref = nil
    loadedVersion = nil
    value = nil
    failure = nil
    isLoading = false
  }

  func isCurrent(version: Int?) -> Bool {
    !isLoading && failure == nil && value != nil && loadedVersion == version
  }

  func load(
    workspace: String, ref: String, version: Int? = nil,
    read: @MainActor () async throws -> AppTask
  ) async {
    if self.workspace != workspace || self.ref != ref { clear() }
    self.workspace = workspace
    self.ref = ref
    generation += 1
    let token = generation
    failure = nil
    isLoading = true
    defer { if token == generation { isLoading = false } }
    do {
      let result = try await read()
      guard token == generation, !Task.isCancelled else { return }
      value = result
      loadedVersion = version
    } catch {
      guard token == generation, !Task.isCancelled else { return }
      failure = AppLoadFailure(error).message
    }
  }
}
