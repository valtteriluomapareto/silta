import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  typealias Loader = @Sendable (AppLoadedData?, String?, Bool) async throws -> AppLoadedData?
  var data: AppLoadedData?
  var workspace: String?
  var screen: AppScreen = .mywork
  var appFilter: String?
  var search = ""
  var isLoading = false
  var failure: AppLoadFailure?
  var lastCheckedAt: Date?
  private let load: Loader
  private let now: @Sendable () -> Date

  init(load: @escaping Loader, now: @escaping @Sendable () -> Date = { Date() }) {
    self.load = load
    self.now = now
  }

  var visibleData: AppLoadedData? { data }

  @discardableResult func refresh(force: Bool = false) -> Task<Void, Never> {
    let previous = data
    let requested = workspace
    isLoading = true
    return Task {
      do {
        data = try await load(previous, requested, force)
        workspace = data?.workspace
        failure = nil
      } catch { failure = AppLoadFailure(error) }
      lastCheckedAt = now()
      isLoading = false
    }
  }

  @discardableResult func selectWorkspace(_ slug: String) -> Task<Void, Never> {
    workspace = slug
    return refresh(force: true)
  }

  func navigate(_ screen: AppScreen) { self.screen = screen; appFilter = nil }
  func selectApp(_ slug: String) { screen = .board; appFilter = slug }
  @discardableResult func focused() -> Task<Void, Never> { refresh() }
  @discardableResult func tick(frontmost: Bool) -> Task<Void, Never>? { frontmost ? refresh() : nil }
}
