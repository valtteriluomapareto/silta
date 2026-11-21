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
  /// The inspected task's worktree when it exists here, checked off the main thread, so a
  /// task outside the board can still be revealed.
  private(set) var inspectedWorktrees: Set<String> = []
  let actions: ActionModel
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
  /// The Board's filters. The Show toggles for blocked and done tasks persist when the
  /// model has defaults; automated runs and tests pass none.
  var boardFilter = BoardFilter() {
    didSet {
      if boardFilter.blocked != oldValue.blocked {
        defaults?.set(boardFilter.blocked, forKey: Self.showBlockedKey)
      }
      if boardFilter.done != oldValue.done {
        defaults?.set(boardFilter.done, forKey: Self.showDoneKey)
      }
    }
  }
  private(set) var boardSelection: BoardSelection?
  var boardInspectorPresented = false
  private(set) var workspaceSelection: ConnectionSelection?
  /// The selected app or service on the map (`app:<slug>` or `service:<slug>`). Exclusive
  /// with `workspaceSelection`.
  private(set) var workspaceNode: String?
  var workspaceView: WorkspaceViewMode = .map
  var workspaceInspectorPresented = false
  /// My work shows the whole inbox instead of the capped read; reset per workspace.
  private(set) var showingAllWaiting = false
  /// The whole inbox while `showingAllWaiting`, read after each load.
  private(set) var allWaiting: [AppAttention]?
  /// Why the last full-inbox read failed; the previous list stays on screen.
  private(set) var allWaitingFailure: String?
  @ObservationIgnored private var allWaitingVersion: Int?
  private(set) var isLoading = false
  private(set) var failure: AppLoadFailure?
  private let load: Loader
  @ObservationIgnored private var flight: Task<Void, Never>?
  @ObservationIgnored private var queuedForce = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private let stateDefaults: UserDefaults?
  static let lastWorkspaceKey = "lastWorkspace"
  static let lastRouteKey = "lastScreen"
  static let showBlockedKey = "boardShowBlocked"
  static let showDoneKey = "boardShowDone"

  /// Where the Board's Show toggles are stored: automated control runs start from the
  /// defaults and store nothing; real launches and hand-launched fixtures share the
  /// human's toggles.
  static func filterDefaults(automated: Bool) -> UserDefaults? {
    automated ? nil : .standard
  }

  /// Where the last workspace and screen and unsent drafts are stored. They belong to the
  /// human's store, so only a real launch reads or writes them; every fixture run starts
  /// fresh and leaves the human's untouched.
  static func stateDefaults(fixture: Bool) -> UserDefaults? {
    fixture ? nil : .standard
  }

  /// Back to the default Board: every lane, all apps, no proposals. Search stays.
  func resetBoardFilter() { boardFilter = BoardFilter() }

  init(
    reader: AppReader? = nil, now: @escaping @Sendable () -> Date = { Date() },
    documents: DocsModel = DocsModel(),
    workspaceDocuments: WorkspaceDocumentsModel = WorkspaceDocumentsModel(),
    writer: Writer? = nil, defaults: UserDefaults? = nil, stateDefaults: UserDefaults? = nil,
    load: @escaping Loader
  ) {
    self.defaults = defaults
    self.stateDefaults = stateDefaults
    actions = ActionModel(defaults: stateDefaults)
    workspace = stateDefaults?.string(forKey: Self.lastWorkspaceKey)
    route = stateDefaults?.string(forKey: Self.lastRouteKey).flatMap(AppRoute.init) ?? .mywork
    boardFilter = BoardFilter(
      blocked: defaults?.object(forKey: Self.showBlockedKey) as? Bool ?? true,
      done: defaults?.object(forKey: Self.showDoneKey) as? Bool ?? true)
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
            // A remembered or selected workspace that no longer exists falls back to the
            // loaded one, dropping what was selected in it.
            if workspace == nil || !result.workspaces.contains(where: { $0.slug == workspace }) {
              if workspace != nil { clearWorkspaceState() }
              workspace = result.workspace
              if let slug = result.workspace {
                stateDefaults?.set(slug, forKey: Self.lastWorkspaceKey)
              }
            }
          }
          failure = nil
          await loadExtras(force: forced, token: token)
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
    stateDefaults?.set(slug, forKey: Self.lastWorkspaceKey)
    if workspace != slug {
      generation += 1
      workspace = slug
      clearWorkspaceState()
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
      documents.ref =
        DocsContent.sections(documents.groups(search: "")).first?.groups.first?
        .preferred?.ref
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

  /// Narrows the list from the reader while keeping the open document and tab.
  func filterDocuments(about: String) {
    docsAbout = about
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
    let path = taskDetail.value?.worktree
    let found = await Task.detached {
      Set(
        [path].compactMap { $0 }.filter {
          $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0)
        })
    }.value
    if taskDetail.value?.ref == ref { inspectedWorktrees = found }
  }

  func navigate(to route: AppRoute) {
    self.route = route
    stateDefaults?.set(route.rawValue, forKey: Self.lastRouteKey)
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

  /// Shows every waiting item in My work, past the inbox cap.
  @discardableResult func showAllWaiting() -> Task<Void, Never> {
    showingAllWaiting = true
    return Task { await loadAllWaiting(force: true) }
  }

  /// Back to the capped inbox.
  func showFewerWaiting() {
    showingAllWaiting = false
    allWaiting = nil
    allWaitingFailure = nil
    allWaitingVersion = nil
  }

  private func loadAllWaiting(force: Bool) async {
    guard let reader, let workspace, let version = visibleData?.version else { return }
    if !force, allWaiting != nil, allWaitingVersion == version { return }
    let token = generation
    do {
      let items = try await Task.detached { try reader.fullInbox(workspace: workspace) }.value
      guard token == generation, showingAllWaiting, self.workspace == workspace,
        visibleData?.version == version
      else { return }
      allWaiting = items
      allWaitingFailure = nil
      allWaitingVersion = version
    } catch {
      // The last list stays on screen; the next refresh tries again.
      guard token == generation, showingAllWaiting else { return }
      allWaitingFailure = AppLoadFailure(error).message
    }
  }

  /// The reads that follow a load: the document catalog, the full inbox when shown, and
  /// the current route's documents. A workspace switch midway stops them.
  private func loadExtras(force: Bool, token: Int) async {
    await loadDocumentCatalog(force: force)
    guard token == generation else { return }
    if showingAllWaiting { await loadAllWaiting(force: force) }
    guard token == generation else { return }
    if route == .docs { await loadDocuments(force: force) }
    if route == .workspace { await loadWorkspaceDocuments(force: force) }
  }

  func toggleInspector() {
    switch route {
    case .board: boardInspectorPresented.toggle()
    case .workspace: workspaceInspectorPresented.toggle()
    case .mywork, .docs: break
    }
  }

  func showApp(_ slug: String) {
    boardFilter.app = slug
    navigate(to: .board)
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

  /// Drops what belongs to the previous workspace: documents, selections, filters by app
  /// and the full inbox.
  private func clearWorkspaceState() {
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
    boardFilter.app = nil
    showingAllWaiting = false
    allWaiting = nil
    allWaitingFailure = nil
    allWaitingVersion = nil
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
    if route == .board, let snapshot = data.snapshot {
      let board = snapshot.board
      let hidden = BoardContent(
        snapshot: snapshot, apps: [], filter: BoardFilter(blocked: boardFilter.blocked), search: ""
      ).hiddenBlocked
      return "\(board.todo.count + board.doing.count + board.review.count) open · "
        + (hidden > 0 ? "\(hidden) blocked hidden · " : "")
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
