#if DEBUG
  import Foundation
  import SiltaAppSupport

  nonisolated struct ControlState: Encodable {
    struct Selection: Encodable, Equatable {
      let kind: String
      let ref: String
      let view: String?
      init(kind: String, ref: String, view: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.view = view
      }
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
    let pid = ProcessInfo.processInfo.processIdentifier
    let windowNumber: Int?
    let seq: Int?
    let settledSeq: Int?
    let run: String
    let revision: Int
    let fixture = "v2"
    let fixtureNow = AppV2Fixture.now.ISO8601Format(.init(includingFractionalSeconds: true))
    let appearance: String
    let screen: String
    let route: String
    let selection: Selection?
    let inspectorOpen: Bool
    let counts: Counts
    let refresh: Refresh
    let idle: Bool

    @MainActor init(
      model: AppModel, run: String, revision: Int, dark: Bool, windowNumber: Int? = nil,
      seq: Int? = nil, settledSeq: Int? = nil
    ) {
      self.windowNumber = windowNumber
      self.seq = seq
      self.settledSeq = settledSeq
      self.run = run
      self.revision = revision
      appearance = dark ? "dark" : "light"
      screen = model.route.rawValue
      let navigation = Self.navigation(model)
      selection = navigation.selection
      inspectorOpen = navigation.inspectorOpen
      route =
        screen
        + (selection.map { selected in
          ":" + selected.ref + (selected.view.map { ":" + $0 } ?? "")
        } ?? "")
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
      let readiness = Self.readiness(model)
      refresh = Refresh(phase: readiness.phase, dataVersion: model.visibleData?.version)
      idle = readiness.idle
    }

    @MainActor static func readiness(_ model: AppModel) -> (phase: String, idle: Bool) {
      let documentPhase =
        model.route == .docs
        ? model.documents.phase(
          workspace: model.workspace, about: model.docsAbout,
          archived: model.includeArchivedDocuments, version: model.visibleData?.version) : nil
      let workspacePhase =
        model.route == .workspace && model.visibleData?.map != nil
        ? model.workspaceDocuments.phase(
          workspace: model.workspace, version: model.visibleData?.version,
          connections: model.visibleData?.map?.connections.map(\.attachment) ?? []) : nil
      let taskPhase =
        model.route == .board && model.boardInspectorPresented
        ? model.boardSelection.map {
          model.taskDetail.phase(
            workspace: model.workspace, ref: $0.taskRef, version: model.visibleData?.version)
        } : nil
      let phase =
        model.isLoading
        ? "loading"
        : model.failure != nil
          ? "failed"
          : workspacePhase?.rawValue ?? documentPhase?.rawValue ?? taskPhase?.rawValue
            ?? (model.data != nil ? "ready" : "starting")
      return (phase, model.actions.sending.isEmpty && (phase == "ready" || phase == "failed"))
    }

    @MainActor static func navigation(_ model: AppModel)
      -> (selection: Selection?, inspectorOpen: Bool)
    {
      switch model.route {
      case .mywork: return (nil, false)
      case .docs:
        return (
          model.documentSelection.map {
            Selection(kind: "document", ref: $0.ref, view: $0.view.rawValue)
          }, false
        )
      case .board:
        return (
          model.boardSelection.map { Selection(kind: "task", ref: $0.taskRef) },
          model.boardInspectorPresented
        )
      case .workspace:
        let connection = model.workspaceSelection.map {
          Selection(kind: "connection", ref: $0.connectionRef)
        }
        return (
          model.workspaceNode.map {
            Selection(kind: $0.hasPrefix("service:") ? "service" : "app", ref: $0)
          } ?? connection,
          model.workspaceInspectorPresented
        )
      }
    }

    enum CodingKeys: String, CodingKey {
      case snapshotVersion, run, revision, fixture, fixtureNow, appearance, screen, route, selection
      case inspectorOpen, counts, refresh, idle, pid, windowNumber, seq, settledSeq
    }
    func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(snapshotVersion, forKey: .snapshotVersion)
      try values.encode(pid, forKey: .pid)
      try values.encode(windowNumber, forKey: .windowNumber)
      try values.encode(seq, forKey: .seq)
      try values.encode(settledSeq, forKey: .settledSeq)
      try values.encode(run, forKey: .run)
      try values.encode(revision, forKey: .revision)
      try values.encode(fixture, forKey: .fixture)
      try values.encode(fixtureNow, forKey: .fixtureNow)
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
