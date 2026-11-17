import Foundation
import Observation
import SiltaAppSupport

@MainActor @Observable
final class AppModel {
  typealias Loader = @Sendable (AppLoadedData?, String?, Bool) async throws -> AppLoadedData?
  private(set) var data: AppLoadedData?
  private(set) var workspace: String?
  let reader: AppReader?
  let taskDetail = TaskDetailModel()
  let documents: DocsModel
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
  var workspaceInspectorPresented = false
  private(set) var isLoading = false
  private(set) var failure: AppLoadFailure?
  private let load: Loader
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var queuedForce = false
  @ObservationIgnored private var generation = 0

  init(
    reader: AppReader? = nil, documents: DocsModel = DocsModel(), load: @escaping Loader
  ) {
    self.reader = reader
    self.documents = documents
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
          if route == .docs { await loadDocuments(force: forced) }
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
      docsAbout = nil
      taskDetail.clear()
      boardSelection = nil
      boardInspectorPresented = false
      workspaceSelection = nil
      workspaceInspectorPresented = false
      appFilter = nil
    }
    return refresh(force: true)
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

  func openDocument(_ ref: String) {
    docsAbout = nil
    documents.view = .changes
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
    await taskDetail.load(workspace: workspace, ref: ref) {
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
    navigate(to: .workspace)
    workspaceInspectorPresented = true
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
  var screenSummary: String {
    guard let data = visibleData else { return "" }
    if route == .docs { return "Workspace documents" }
    if route == .workspace, let map = data.map {
      return
        "\(map.apps.count) apps · \(map.services.count) services · \(map.connections.count) connections"
    }
    if route == .board, let board = data.snapshot?.board {
      return "\(board.todo.count + board.doing.count + board.review.count) open · "
        + "\(board.proposals.count) proposed · \(board.doneThisWeek.count) done this week"
    }
    let claimed = data.snapshot?.board.doing.filter { $0.claimedBy != nil }.count ?? 0
    return
      "\(data.snapshot?.work.waitingCount ?? 0) waiting on you · \(claimed) tasks claimed"
  }

}
