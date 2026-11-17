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
  private(set) var route: AppRoute = .mywork
  var appFilter: String?
  private(set) var boardSelection: BoardSelection?
  var boardInspectorPresented = false
  var showProposed = false
  private(set) var workspaceSelection: ConnectionSelection?
  var workspaceInspectorPresented = false
  private(set) var isLoading = false
  private(set) var failure: AppLoadFailure?
  private let load: Loader
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var queuedForce = false
  @ObservationIgnored private var generation = 0

  init(
    reader: AppReader? = nil, load: @escaping Loader
  ) {
    self.reader = reader
    self.load = load
  }

  func matches(_ values: [String]) -> Bool {
    AppSearch.matches(search, values: values)
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

  var hasWorkMatches: Bool {
    guard let work = visibleData?.snapshot?.work else { return false }
    return work.items.contains(where: matches)
      || work.reviews.contains { matches([$0.ref, $0.title, $0.description]) }
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
        }
      } catch {
        if token == generation {
          failure = AppLoadFailure(error)
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
      boardSelection = nil
      boardInspectorPresented = false
      workspaceSelection = nil
      workspaceInspectorPresented = false
      appFilter = nil
    }
    return refresh(force: true)
  }

  func navigate(to route: AppRoute) {
    self.route = route
  }

  func inspect(task ref: String) {
    boardSelection = BoardSelection(taskRef: ref)
    navigate(to: .board)
    boardInspectorPresented = true
  }

  func select(connection ref: String) {
    workspaceSelection = ConnectionSelection(connectionRef: ref)
    navigate(to: .workspace)
    workspaceInspectorPresented = true
  }

  func toggleInspector() {
    switch route {
    case .board: boardInspectorPresented.toggle()
    case .workspace: workspaceInspectorPresented.toggle()
    case .mywork: break
    }
  }

  func showApp(_ slug: String) {
    appFilter = slug
    navigate(to: .board)
  }

  @discardableResult func tick(frontmost: Bool) -> Task<Void, Never>? {
    frontmost ? refresh() : nil
  }
}

nonisolated struct BoardSelection: Equatable {
  let taskRef: String
}

nonisolated struct ConnectionSelection: Equatable {
  let connectionRef: String
}
