import Observation
import SiltaAppSupport

@MainActor @Observable final class WorkspaceDocumentsModel {
  typealias Loader =
    @MainActor (AppReader, String, [String]) async throws -> [String: AppDocumentList]
  enum Phase: String { case starting, loading, ready, failed }
  private struct Key: Equatable {
    let workspace: String
    let version: Int?
    let connections: [String]
  }
  private let read: Loader
  private(set) var pages: [String: AppDocumentList] = [:]
  private(set) var failure: String?
  private(set) var loading = false
  private var workspace: String?
  private var loaded: Key?
  private var requested: Key?
  private var generation = 0
  @ObservationIgnored private var flight: Task<Void, Never>?

  init(
    read: @escaping Loader = { reader, workspace, connections in
      try await Task.detached {
        var pages: [String: AppDocumentList] = [:]
        for ref in connections {
          pages[ref] = try reader.documents(workspace: workspace, about: ref)
        }
        return pages
      }.value
    }
  ) { self.read = read }

  func clear() {
    generation += 1
    flight?.cancel()
    flight = nil
    workspace = nil
    requested = nil
    loaded = nil
    pages = [:]
    failure = nil
    loading = false
  }

  func phase(workspace: String?, version: Int?, connections: [String]) -> Phase {
    guard let workspace else { return .starting }
    let key = Key(workspace: workspace, version: version, connections: connections.sorted())
    if loading || requested != key { return .loading }
    if failure != nil { return .failed }
    return loaded == key ? .ready : .loading
  }

  func refresh(
    _ reader: AppReader, workspace: String, version: Int?, connections: [String],
    force: Bool = false
  ) async {
    let key = Key(workspace: workspace, version: version, connections: connections.sorted())
    if !force, loaded == key, failure == nil { return }
    if requested == key, let flight {
      await flight.value
      return
    }
    if self.workspace != workspace { clear() }
    self.workspace = workspace
    flight?.cancel()
    generation += 1
    let token = generation
    requested = key
    loading = true
    failure = nil
    let operation = Task { await perform(reader, key: key, token: token) }
    flight = operation
    await operation.value
  }

  private func perform(_ reader: AppReader, key: Key, token: Int) async {
    defer {
      if token == generation {
        loading = false
        flight = nil
      }
    }
    do {
      let value = try await read(reader, key.workspace, key.connections)
      guard token == generation, !Task.isCancelled else { return }
      pages = value
      loaded = key
    } catch {
      if token == generation, !Task.isCancelled { failure = AppLoadFailure(error).message }
    }
  }

  func groups(for connection: String) -> [DocsModel.Group] {
    DocsContent.groups(pages[connection]?.entries ?? [])
  }

  func countText(for connection: String) -> String? {
    guard let page = pages[connection] else { return nil }
    return "\(groups(for: connection).count)" + (page.nextOffset == nil ? "" : "+")
  }

  func countLabel(for connection: String) -> String {
    guard let count = countText(for: connection) else {
      return failure == nil ? "…" : "Unavailable"
    }
    if count == "0" { return "No docs" }
    return count + (count == "1" ? " doc" : " docs")
  }
}
