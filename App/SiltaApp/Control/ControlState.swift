#if DEBUG
  import Foundation
  import SiltaAppSupport

  nonisolated struct ControlState: Encodable {
    struct Selection: Encodable {
      let kind: String
      let ref: String
    }
    struct Sidebar: Encodable {
      let waiting: Int
      let claimed: Int
      let apps: [String: Int]
    }
    struct Counts: Encodable {
      let lanes: [String: Int]?
      let sidebar: Sidebar?
      func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: ControlCountsKeys.self)
        try values.encode(lanes, forKey: .lanes)
        try values.encode(sidebar, forKey: .sidebar)
      }
    }
    struct Refresh: Encodable {
      let phase: String
      let dataVersion: Int?
      func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: ControlRefreshKeys.self)
        try values.encode(phase, forKey: .phase)
        try values.encode(dataVersion, forKey: .dataVersion)
      }
    }
    let snapshotVersion = 1
    let run: String
    let revision: Int
    let fixture = "v2"
    let appearance: String
    let screen: String
    let route: String
    let selection: Selection?
    let inspectorOpen: Bool
    let counts: Counts
    let refresh: Refresh
    let idle: Bool

    @MainActor init(model: AppModel, run: String, revision: Int, dark: Bool) {
      self.run = run
      self.revision = revision
      appearance = dark ? "dark" : "light"
      screen = model.route.rawValue
      switch model.route {
      case .mywork:
        selection = nil
        inspectorOpen = false
      case .board:
        selection = model.boardSelection.map { Selection(kind: "task", ref: $0.taskRef) }
        inspectorOpen = model.boardInspectorPresented
      case .workspace:
        selection = model.workspaceSelection.map {
          Selection(kind: "connection", ref: $0.connectionRef)
        }
        inspectorOpen = model.workspaceInspectorPresented
      }
      route = screen + (selection.map { ":" + $0.ref } ?? "")
      if let snapshot = model.visibleData?.snapshot {
        let content = BoardContent(
          snapshot: snapshot, app: model.appFilter, search: model.search,
          proposals: model.showProposed)
        counts = Counts(
          lanes: Dictionary(uniqueKeysWithValues: content.lanes.map { ($0.title, $0.tasks.count) }),
          sidebar: Sidebar(
            waiting: snapshot.work.waitingCount,
            claimed: snapshot.board.doing.filter { $0.claimedBy != nil }.count,
            apps: snapshot.board.appOpenCounts))
      } else {
        counts = Counts(lanes: nil, sidebar: nil)
      }
      let phase =
        model.isLoading
        ? "loading" : model.failure != nil ? "failed" : model.data != nil ? "ready" : "starting"
      refresh = Refresh(phase: phase, dataVersion: model.visibleData?.version)
      let taskSettled =
        model.route != .board || !model.boardInspectorPresented
        || model.boardSelection == nil
        || (model.taskDetail.value?.ref == model.boardSelection?.taskRef
          || model.taskDetail.failure != nil)
      idle =
        !model.isLoading && !model.taskDetail.isLoading && taskSettled
        && (model.data != nil || model.failure != nil)
    }

    enum CodingKeys: String, CodingKey {
      case snapshotVersion, run, revision, fixture, appearance, screen, route, selection
      case inspectorOpen, counts, refresh, idle
    }
    func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(snapshotVersion, forKey: .snapshotVersion)
      try values.encode(run, forKey: .run)
      try values.encode(revision, forKey: .revision)
      try values.encode(fixture, forKey: .fixture)
      try values.encode(appearance, forKey: .appearance)
      try values.encode(screen, forKey: .screen)
      try values.encode(route, forKey: .route)
      try values.encode(selection, forKey: .selection)
      try values.encode(inspectorOpen, forKey: .inspectorOpen)
      try values.encode(counts, forKey: .counts)
      try values.encode(refresh, forKey: .refresh)
      try values.encode(idle, forKey: .idle)
    }
    func write(to url: URL) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(self).write(to: url, options: .atomic)
    }
  }
  private nonisolated enum ControlCountsKeys: String, CodingKey { case lanes, sidebar }
  private nonisolated enum ControlRefreshKeys: String, CodingKey { case phase, dataVersion }
#endif
