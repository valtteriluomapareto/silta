import Foundation
import Observation
import SiltaAppSupport

@MainActor @Observable
final class AppModel {
  typealias Loader = @Sendable (AppLoadedData?, String?, Bool) async throws -> AppLoadedData?
  private(set) var data: AppLoadedData?
  private(set) var workspace: String?
  let reader: AppReader?
  var search = ""
  private(set) var isLoading = false
  private(set) var failure: AppLoadFailure?
  private(set) var lastCheckedAt: Date?
  private let load: Loader
  private let now: @Sendable () -> Date
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var queuedForce = false
  @ObservationIgnored private var generation = 0

  init(
    reader: AppReader? = nil, load: @escaping Loader,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.reader = reader
    self.load = load
    self.now = now
  }

  func matches(_ values: [String]) -> Bool {
    search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
  }

  func matches(_ item: AppAttention) -> Bool {
    matches(
      [
        item.kind, item.ref ?? "", item.task ?? "", item.title ?? "", item.body ?? "",
        item.author ?? "",
      ] + item.refs)
  }

  var proposals: [AppAttention] {
    visibleData?.snapshot?.work.items.filter { $0.kind == "proposal" && matches($0) } ?? []
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
    }
    return refresh(force: true)
  }

  @discardableResult func focused() -> Task<Void, Never> { refresh() }
  @discardableResult func tick(frontmost: Bool) -> Task<Void, Never>? {
    frontmost ? refresh() : nil
  }
}
