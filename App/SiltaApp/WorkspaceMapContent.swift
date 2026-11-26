import Foundation
import SiltaAppSupport

/// What the map shows for the current selection and search: which edges are strong or
/// faded, which nodes fade, and what VoiceOver reads.
nonisolated struct WorkspaceMapContent {
  struct Edge {
    let connection: AppConnection
    let back: Bool
    /// Parallel forward connections between the same pair get their own lane; back edges
    /// each get a lane of their own across the whole map. An edge to a service takes slot
    /// `lane` of `lanes` across its app's bottom edge, in services-row order.
    let lane: Int
    var lanes = 1
    var toService = false
  }

  /// `quiet` is an unselected line to a service: drawn faint and without a label.
  enum Style: Equatable { case normal, strong, faded, quiet }

  let edges: [Edge]
  private let layout: AppMapLayout
  private let map: AppWorkspaceMap
  private let node: String?
  private let connection: String?
  private let highlighted: Set<String>?
  private let unmatched: Set<String>

  init(
    map: AppWorkspaceMap, layout: AppMapLayout, node: String?, connection: String?,
    search: String
  ) {
    self.map = map
    self.layout = layout
    self.node = node
    self.connection = connection
    var seen: [String: Int] = [:]
    var backLane = 0
    let order = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.key, $0.row) })
    let toServices = Dictionary(
      grouping: map.connections.filter { layout.node($0.target)?.isService == true },
      by: \.source
    ).mapValues { edges in
      edges.sorted {
        (order[$0.target] ?? 0, $0.attachment) < (order[$1.target] ?? 0, $1.attachment)
      }.map(\.attachment)
    }
    edges = map.connections.sorted { $0.attachment < $1.attachment }.map { edge in
      if let slots = toServices[edge.source], let slot = slots.firstIndex(of: edge.attachment) {
        return Edge(
          connection: edge, back: false, lane: slot, lanes: slots.count, toService: true)
      }
      if layout.backEdges.contains(edge.attachment) {
        defer { backLane += 1 }
        return Edge(connection: edge, back: true, lane: backLane)
      }
      let pair = edge.source + ">" + edge.target
      let lane = seen[pair, default: 0]
      seen[pair] = lane + 1
      return Edge(connection: edge, back: false, lane: lane)
    }
    if let node, let selected = layout.nodes.first(where: { $0.attachment == node }) {
      var keys: Set<String> = [selected.key]
      for edge in map.connections where edge.source == selected.key || edge.target == selected.key {
        keys.insert(edge.source)
        keys.insert(edge.target)
      }
      highlighted = keys
    } else {
      highlighted = nil
    }
    unmatched = Self.unmatched(map: map, layout: layout, search: search)
  }

  /// Nodes that a search fades: the same fields the List searches, and a node stays when
  /// it matches itself or any connection it takes part in matches.
  private static func unmatched(map: AppWorkspaceMap, layout: AppMapLayout, search: String)
    -> Set<String>
  {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return [] }
    func matches(_ values: [String]) -> Bool {
      values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    var kept: Set<String> = []
    for app in map.apps
    where matches([app.slug, app.name, app.ref, app.repo, app.summary ?? "", app.attachment]) {
      kept.insert(app.slug)
    }
    for service in map.services
    where matches([service.slug, service.name, service.summary ?? "", service.attachment]) {
      kept.insert(service.key)
    }
    for edge in map.connections
    where matches([edge.attachment, edge.target, edge.kind, edge.summary] + edge.codeReferences) {
      kept.insert(edge.source)
      kept.insert(edge.target)
    }
    return Set(layout.nodes.map(\.key)).subtracting(kept)
  }

  func isFaded(_ attachment: String) -> Bool {
    guard let node = layout.nodes.first(where: { $0.attachment == attachment }) else {
      return false
    }
    return unmatched.contains(node.key) || highlighted.map { !$0.contains(node.key) } ?? false
  }

  func style(_ edge: Edge) -> Style {
    let ends = [edge.connection.source, edge.connection.target]
    if connection == edge.connection.attachment { return .strong }
    if let node, let selected = layout.nodes.first(where: { $0.attachment == node }) {
      return ends.contains(selected.key) ? .strong : .faded
    }
    if ends.contains(where: { unmatched.contains($0) }) { return .faded }
    return edge.toService ? .quiet : .normal
  }

  /// Whether an edge shows its label: always for app-to-app edges, and for a line to a
  /// service only while it is strong.
  func showsLabel(_ edge: Edge) -> Bool { !edge.toService || style(edge) == .strong }

  /// The number of distinct apps that call a service.
  func callers(of service: String) -> Int {
    Set(map.connections.filter { $0.target == service }.map(\.source)).count
  }

  /// The label on an edge: its kind, plus a doc count when it has docs.
  static func labelText(kind: String, docs: String?) -> String {
    guard let docs, docs != "0" else { return kind }
    return kind + " · " + docs + (docs == "1" ? " doc" : " docs")
  }

  /// VoiceOver text for a node: what it is and every connection it takes part in.
  func description(_ node: AppMapLayout.Node) -> String {
    let outgoing = map.connections.filter { $0.source == node.key }.map {
      "calls \(map.endpointName($0.target)) over \($0.kind)"
    }
    let incoming = map.connections.filter { $0.target == node.key }.map {
      "called by \(map.endpointName($0.source)) over \($0.kind)"
    }
    return ([map.endpointName(node.key), node.isService ? "service" : "app"] + outgoing + incoming)
      .joined(separator: ", ")
  }

  /// VoiceOver text for a connection label.
  func description(_ edge: Edge, docs: String?) -> String {
    let count = docs.map { $0 == "1" ? "1 doc" : "\($0) docs" } ?? "docs not loaded"
    return "\(map.endpointName(edge.connection.source)) calls "
      + "\(map.endpointName(edge.connection.target)) over "
      + "\(edge.connection.kind), \(count)"
  }
}
