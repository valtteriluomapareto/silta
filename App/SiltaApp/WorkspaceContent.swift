import Foundation
import SiltaAppSupport

nonisolated struct WorkspaceContent {
  struct Group: Identifiable {
    let app: AppMapApp
    let connections: [AppConnection]
    var id: String { app.slug }
  }
  let groups: [Group]
  let services: [AppMapService]
  private let connections: [AppConnection]

  init(map: AppWorkspaceMap, search: String) {
    func matches(_ values: [String]) -> Bool {
      search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }
    connections = map.connections
    groups = map.apps.compactMap { app in
      let appMatches = matches([
        app.slug, app.name, app.ref, app.repo, app.summary ?? "", app.attachment,
      ])
      let edges = map.connections.filter { edge in
        edge.source == app.slug
          && (appMatches
            || matches(
              [edge.attachment, edge.target, edge.kind, edge.summary] + edge.codeReferences))
      }
      return appMatches || !edges.isEmpty ? Group(app: app, connections: edges) : nil
    }
    services = map.services.filter { matches([$0.slug, $0.name, $0.summary ?? "", $0.attachment]) }
  }

  func connection(_ attachment: String?) -> AppConnection? {
    connections.first { $0.attachment == attachment }
  }
}
