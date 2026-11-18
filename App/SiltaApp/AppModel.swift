import Foundation
import Observation
import SiltaAppSupport

@MainActor @Observable
final class AppModel {
  typealias Loader = @Sendable (AppLoadedData?, String?, Bool) async throws -> AppLoadedData?
  typealias Writer = @Sendable (AppWrite, String) async throws -> Void
  private(set) var data: AppLoadedData?
  private(set) var workspace: String?
  let reader: AppReader?
  let now: @Sendable () -> Date
  private(set) var documentCatalog: AppDocumentList?
  private(set) var catalogFailure: String?
  private var catalogWorkspace: String?
  private var catalogVersion: Int?
  let taskDetail = TaskDetailModel()
  let actions = ActionModel()
  /// Runs one write in a workspace; nil where the app can't write (no store, previews).
  let writer: Writer?
  let documents: DocsModel
  let workspaceDocuments: WorkspaceDocumentsModel
  var docsAbout: String?
  var includeArchivedDocuments = false
  var documentSelection: DocumentSelection? {
    documents.ref.map { DocumentSelection(ref: $0, view: documents.view) }
  }
  var search = ""
  private(set) var route: AppRoute = .mywork
  var appFilter: String?
  private(set) var boardSelection: BoardSelection?
  var boardInspectorPresented = false
  var showProposed = false
  private(set) var workspaceSelection: ConnectionSelection?
  /// The selected app or service on the map (`app:<slug>` or `service:<slug>`). Exclusive
  /// with `workspaceSelection`.
  private(set) var workspaceNode: String?
  var workspaceView: WorkspaceViewMode = .map
  var workspaceInspectorPresented = false
  private(set) var isLoading = false
  private(set) var failure: AppLoadFailure?
  private let load: Loader
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var queuedForce = false
  @ObservationIgnored private var generation = 0

  init(
    reader: AppReader? = nil, now: @escaping @Sendable () -> Date = { Date() },
    documents: DocsModel = DocsModel(),
    workspaceDocuments: WorkspaceDocumentsModel = WorkspaceDocumentsModel(),
    writer: Writer? = nil, load: @escaping Loader
  ) {
    self.reader = reader
    self.writer = writer
    self.now = now
    self.documents = documents
    self.workspaceDocuments = workspaceDocuments
    self.load = load
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
          await loadDocumentCatalog(force: forced)
          guard token == generation else { continue }
          if route == .docs { await loadDocuments(force: forced) }
          if route == .workspace { await loadWorkspaceDocuments(force: forced) }
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
      documents.clear()
      documentCatalog = nil
      catalogFailure = nil
      catalogWorkspace = nil
      catalogVersion = nil
      workspaceDocuments.clear()
      docsAbout = nil
      taskDetail.clear()
      actions.selectedProposals = []
      boardSelection = nil
      boardInspectorPresented = false
      workspaceSelection = nil
      workspaceNode = nil
      workspaceInspectorPresented = false
      appFilter = nil
    }
    return refresh(force: true)
  }

  func loadWorkspaceDocuments(force: Bool = false) async {
    guard let reader, let workspace, let map = visibleData?.map else { return }
    await workspaceDocuments.refresh(
      reader, workspace: workspace, version: visibleData?.version,
      connections: map.connections.map(\.attachment), force: force)
  }

  func loadDocuments(force: Bool = false, append: Bool = false) async {
    guard let reader, let workspace else { return }
    let token = generation
    let about = docsAbout
    let archived = includeArchivedDocuments
    let version = visibleData?.version
    let request = await documents.refresh(
      reader, workspace: workspace, about: about,
      archived: archived, version: version, force: force, append: append)
    guard !Task.isCancelled, token == generation, self.workspace == workspace,
      docsAbout == about, includeArchivedDocuments == archived, visibleData?.version == version,
      let request, documents.isCurrentList(request)
    else { return }
    if documents.ref == nil {
      documents.ref = documents.groups(search: "").first?.preferred?.ref
    }
    await documents.show(reader, workspace: workspace, version: version, force: force)
  }

  func select(document ref: String?) {
    documents.ref = ref
    navigate(to: .docs)
  }

  func select(documentView view: AppDocumentView) {
    documents.view = view
  }

  func openDocument(_ ref: String, view: AppDocumentView = .changes, about: String? = nil) {
    docsAbout = about
    documents.view = view
    select(document: ref)
  }

  func openDocuments(about: String) {
    docsAbout = about
    documents.ref = nil
    documents.view = .document
    navigate(to: .docs)
  }

  func loadTaskDetail() async {
    guard let reader, let workspace, let ref = boardSelection?.taskRef else {
      taskDetail.clear()
      return
    }
    await taskDetail.load(workspace: workspace, ref: ref, version: visibleData?.version) {
      try await Task.detached { try reader.task(ref, workspace: workspace) }.value
    }
  }

  func navigate(to route: AppRoute) {
    self.route = route
  }

  func inspect(task ref: String) {
    if boardSelection?.taskRef != ref { taskDetail.clear() }
    boardSelection = BoardSelection(taskRef: ref)
    navigate(to: .board)
    boardInspectorPresented = true
  }

  func select(connection ref: String) {
    workspaceSelection = ConnectionSelection(connectionRef: ref)
    workspaceNode = nil
    navigate(to: .workspace)
    workspaceInspectorPresented = true
  }

  /// Selects an app or service on the map by its map reference.
  func select(node ref: String) {
    workspaceNode = ref
    workspaceSelection = nil
    navigate(to: .workspace)
    workspaceInspectorPresented = true
  }

  func clearWorkspaceSelection() {
    workspaceNode = nil
    workspaceSelection = nil
  }

  /// Moves the map selection with an arrow key. A selected connection starts from its
  /// source going left and its target going right.
  func moveMapSelection(_ direction: AppMapLayout.Direction) {
    guard let map = visibleData?.map else { return }
    let layout = AppMapLayout(map: map)
    var start = workspaceNode
    if start == nil, let ref = workspaceSelection?.connectionRef,
      let edge = map.connections.first(where: { $0.attachment == ref })
    {
      start = layout.node(direction == .left ? edge.source : edge.target)?.attachment
      if let start { return select(node: start) }
    }
    if let next = layout.neighbour(of: start, direction, connections: map.connections) {
      select(node: next)
    }
  }

  func toggleInspector() {
    switch route {
    case .board: boardInspectorPresented.toggle()
    case .workspace: workspaceInspectorPresented.toggle()
    case .mywork, .docs: break
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

nonisolated enum WorkspaceViewMode: String, CaseIterable {
  case map, list
}

nonisolated struct BoardSelection: Equatable {
  let taskRef: String
}

nonisolated struct ConnectionSelection: Equatable {
  let connectionRef: String
}

nonisolated struct DocumentSelection: Equatable {
  let ref: String
  let view: AppDocumentView
}

extension AppModel {
  private func loadDocumentCatalog(force: Bool) async {
    guard let reader, let workspace, let data = visibleData else { return }
    if !force, documentCatalog != nil, catalogFailure == nil,
      catalogWorkspace == workspace, catalogVersion == data.version
    {
      return
    }
    let token = generation
    do {
      let page = try await Task.detached {
        try reader.documents(workspace: workspace, archived: true)
      }.value
      guard token == generation, self.workspace == workspace, visibleData?.version == data.version
      else { return }
      documentCatalog = page
      catalogWorkspace = workspace
      catalogVersion = data.version
      catalogFailure = nil
    } catch {
      if token == generation, self.workspace == workspace {
        catalogFailure = AppLoadFailure(error).message
      }
    }
  }

  var screenTitle: String {
    route == .docs ? documents.document.map { $0.title ?? $0.slug } ?? "Docs" : route.title
  }

  var screenSummary: String {
    guard let data = visibleData else { return "" }
    if route == .docs {
      guard let doc = documents.document else { return "Workspace documents" }
      let count = documents.versions.filter { $0.state == "proposed" }.count
      let qualifier = documents.nextVersions == nil ? "" : " in loaded history"
      return "\(doc.kind ?? "Document") · \(doc.state) revision @\(doc.revision) · "
        + "\(count) proposed" + qualifier
    }
    if route == .workspace, let map = data.map {
      return
        "\(map.apps.count) apps · \(map.services.count) services · \(map.connections.count) connections"
    }
    if route == .board, let board = data.snapshot?.board {
      return "\(board.todo.count + board.doing.count + board.review.count) open · "
        + "\(board.proposals.count) proposed · \(board.doneThisWeek.count) done this week"
    }
    return "\(data.snapshot?.work.waitingCount ?? 0) waiting on you"
  }

  /// The large in-content title. Docs keeps the document's title in its reader.
  var headerTitle: String { route.title }

  var headerSummary: String {
    guard route == .docs else { return screenSummary }
    return DocsChromeContent.catalogSummary(documentCatalog, stale: catalogFailure != nil)
  }

}
