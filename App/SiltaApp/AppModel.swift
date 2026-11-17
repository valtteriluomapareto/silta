import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  typealias Loader = @Sendable (AppLoadedData?, String?, Bool) async throws -> AppLoadedData?
  private(set) var data: AppLoadedData?
  private(set) var workspace: String?
  private(set) var screen: AppScreen = .mywork
  private(set) var appFilter: String?
  var search = ""
  private(set) var isLoading = false
  private(set) var failure: AppLoadFailure?
  private(set) var lastCheckedAt: Date?
  private let load: Loader
  private let now: @Sendable () -> Date
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var queuedForce = false
  @ObservationIgnored private var generation = 0

  init(load: @escaping Loader, now: @escaping @Sendable () -> Date = { Date() }) {
    self.load = load
    self.now = now
  }

  var visibleData: AppLoadedData? { data?.workspace == workspace ? data : nil }

  @discardableResult func refresh(force: Bool = false) -> Task<Void, Never> {
    if let flight {
      queuedForce = queuedForce || force
      return flight
    }
    isLoading = true
    let task = Task { await drain(force: force) }
    flight = task
    return task
  }

  private func drain(force: Bool) async {
    var forceNext = force
    repeat {
      let forced = forceNext || queuedForce || failure != nil
      queuedForce = false
      let requested = workspace
      let token = generation
      do {
        let result = try await load(data, requested, forced)
        if token == generation {
          if let result {
            data = result
            if workspace == nil { workspace = result.workspace }
          }
          failure = nil
          lastCheckedAt = now()
        }
      } catch {
        if token == generation {
          failure = AppLoadFailure(error)
          lastCheckedAt = now()
        }
      }
      forceNext = true
    } while queuedForce
    isLoading = false
    flight = nil
  }

  @discardableResult func selectWorkspace(_ slug: String) -> Task<Void, Never> {
    if workspace != slug {
      generation += 1
      workspace = slug
      appFilter = nil
    }
    return refresh(force: true)
  }

  func navigate(_ screen: AppScreen) {
    self.screen = screen
    appFilter = nil
  }
  func selectApp(_ slug: String) {
    screen = .board
    appFilter = slug
  }
  @discardableResult func focused() -> Task<Void, Never> { refresh() }
  @discardableResult func tick(frontmost: Bool) -> Task<Void, Never>? {
    frontmost ? refresh() : nil
  }
}
