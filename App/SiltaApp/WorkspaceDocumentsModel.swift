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
  private var countsStale = false
  private var generation = 0
  @ObservationIgnored private var flight: Task<Void, Never>?

  init(
    read: @escaping Loader = { reader, workspace, connections in
      let operation = Task.detached {
        try WorkspaceDocumentsModel.readPages(connections: connections) {
          try reader.documents(workspace: workspace, about: $0)
        }
      }
      return try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
    }
  ) { self.read = read }

  nonisolated static func readPages(
    connections: [String], read: (String) throws -> AppDocumentList
  ) throws -> [String: AppDocumentList] {
    var pages: [String: AppDocumentList] = [:]
    for ref in connections {
      try Task.checkCancellation()
      pages[ref] = try read(ref)
    }
    return pages
  }

  func clear() {
    generation += 1
    flight?.cancel()
    flight = nil
    workspace = nil
    requested = nil
    loaded = nil
    pages = [:]
    countsStale = false
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
    if requested == key, let flight {
      await flight.value
      return
    }
    if !force, loaded == key, failure == nil { return }
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
      countsStale = false
    } catch {
      if token == generation, !Task.isCancelled {
        failure = AppLoadFailure(error).message
        countsStale = true
      }
    }
  }

  func groups(for connection: String) -> [DocsModel.Group] {
    DocsContent.groups(pages[connection]?.entries ?? [])
  }

  private func rawCountText(for connection: String) -> String? {
    guard let page = pages[connection] else { return nil }
    return "\(groups(for: connection).count)" + (page.nextOffset == nil ? "" : "+")
  }

  func countText(for connection: String) -> String? {
    rawCountText(for: connection).map { $0 + (countsStale ? " (stale)" : "") }
  }

  func countLabel(for connection: String) -> String {
    guard let count = rawCountText(for: connection) else {
      return failure == nil ? "…" : "Unavailable"
    }
    let text = count == "0" ? "No docs" : count + (count == "1" ? " doc" : " docs")
    return text + (countsStale ? " (stale)" : "")
  }
}
