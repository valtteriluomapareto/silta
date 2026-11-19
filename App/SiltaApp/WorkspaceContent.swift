import Foundation
import SiltaAppSupport

/// The Workspace list: one row per app in call order (the map's columns), with its
/// connections for the open row, then the services, most shared first.
nonisolated struct WorkspaceContent {
  struct AppRow: Identifiable {
    let app: AppMapApp
    /// Connections from other apps, in call order of the caller.
    let calledBy: [AppConnection]
    /// Connections to other apps, in call order of the target.
    let calls: [AppConnection]
    /// Connections to services, most shared service first, then by slug.
    let uses: [AppConnection]
    var id: String { app.slug }

    /// Each used service's slug once, in `uses` order.
    var services: [String] {
      var seen: Set<String> = []
      return uses.map { String($0.target.dropFirst("service:".count)) }
        .filter { seen.insert($0).inserted }
    }
  }

  struct ServiceRow: Identifiable {
    let service: AppMapService
    /// Connections to this service, in call order of the app.
    let users: [AppConnection]
    var id: String { service.slug }
    var apps: Int { Set(users.map(\.source)).count }
  }

  let apps: [AppRow]
  /// Services used by more than one app, shown in full.
  let shared: [ServiceRow]
  /// The rest, folded into one line. When no service is shared, `shared` holds them all.
  let folded: [ServiceRow]
  private let connections: [AppConnection]

  init(map: AppWorkspaceMap, search: String) {
    let query = search.trimmingCharacters(in: .whitespaces)
    func matches(_ values: [String]) -> Bool {
      query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    func matches(_ edge: AppConnection) -> Bool {
      matches([edge.attachment, edge.source, edge.target, edge.kind, edge.summary] + edge.codeReferences)
    }
    connections = map.connections
    let layout = AppMapLayout(map: map)
    let position = Dictionary(
      uniqueKeysWithValues: layout.nodes.enumerated().map { ($1.key, $0) })
    func ordered(_ edges: [AppConnection], by end: KeyPath<AppConnection, String>)
      -> [AppConnection]
    {
      edges.sorted {
        (position[$0[keyPath: end]] ?? .max, $0.attachment)
          < (position[$1[keyPath: end]] ?? .max, $1.attachment)
      }
    }
    let callers = Dictionary(grouping: map.connections, by: \.target).mapValues {
      Set($0.map(\.source)).count
    }
    let apps = Dictionary(uniqueKeysWithValues: map.apps.map { ($0.slug, $0) })
    self.apps = layout.nodes.filter { !$0.isService }.compactMap { node in
      guard let app = apps[node.key] else { return nil }
      let touching = map.connections.filter { $0.source == app.slug || $0.target == app.slug }
      guard
        matches([app.slug, app.name, app.ref, app.repo, app.summary ?? "", app.attachment])
          || touching.contains(where: matches)
      else { return nil }
      let outgoing = map.connections.filter { $0.source == app.slug }
      let uses = outgoing.filter { layout.node($0.target)?.isService == true }.sorted {
        ((-(callers[$0.target] ?? 0)), $0.target, $0.attachment)
          < ((-(callers[$1.target] ?? 0)), $1.target, $1.attachment)
      }
      return AppRow(
        app: app,
        calledBy: ordered(map.connections.filter { $0.target == app.slug }, by: \.source),
        calls: ordered(outgoing.filter { apps[$0.target] != nil }, by: \.target),
        uses: uses)
    }
    let services = map.services.compactMap { service -> ServiceRow? in
      let users = map.connections.filter { $0.target == service.attachment }
      guard
        matches([service.slug, service.name, service.summary ?? "", service.attachment])
          || users.contains(where: matches)
      else { return nil }
      return ServiceRow(service: service, users: ordered(users, by: \.source))
    }.sorted { ($1.apps, $0.service.slug) < ($0.apps, $1.service.slug) }
    let shared = services.filter { $0.apps > 1 }
    self.shared = shared.isEmpty ? services : shared
    folded = shared.isEmpty ? [] : services.filter { $0.apps <= 1 }
  }

  func connection(_ attachment: String?) -> AppConnection? {
    connections.first { $0.attachment == attachment }
  }

  /// The keys of the nodes a selected node connects to, either way; empty without one.
  func related(to key: String?) -> Set<String> {
    guard let key else { return [] }
    return Set(
      connections.compactMap {
        $0.source == key ? $0.target : $0.target == key ? $0.source : nil
      }
    ).subtracting([key])
  }
}
