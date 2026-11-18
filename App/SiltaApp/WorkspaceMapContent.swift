import Foundation
import SiltaAppSupport

/// What the map shows for the current selection and search: which edges are strong or
/// faded, which nodes fade, and what VoiceOver reads.
nonisolated struct WorkspaceMapContent {
  struct Edge {
    let connection: AppConnection
    let back: Bool
    /// Parallel connections between the same pair get their own lane.
    let lane: Int
  }

  enum Style: Equatable { case normal, strong, faded }

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
    edges = map.connections.sorted { $0.attachment < $1.attachment }.map { edge in
      let pair = edge.source + ">" + edge.target
      let lane = seen[pair, default: 0]
      seen[pair] = lane + 1
      return Edge(connection: edge, back: layout.backEdges.contains(edge.attachment), lane: lane)
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
    let query = search.trimmingCharacters(in: .whitespaces)
    unmatched =
      query.isEmpty
      ? []
      : Set(
        layout.nodes.filter { node in
          let app = map.apps.first { $0.slug == node.key }
          let values = [node.key, app?.name ?? "", app?.summary ?? ""]
          return !values.contains { $0.localizedCaseInsensitiveContains(query) }
        }.map(\.key))
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
    return ends.contains { unmatched.contains($0) } ? .faded : .normal
  }

  /// The label on an edge: its kind, plus a doc count when it has docs.
  static func labelText(kind: String, docs: String?) -> String {
    guard let docs, docs != "0" else { return kind }
    return kind + " · " + docs + (docs == "1" ? " doc" : " docs")
  }

  /// VoiceOver text for a node: what it is and every connection it takes part in.
  func description(_ node: AppMapLayout.Node) -> String {
    let outgoing = map.connections.filter { $0.source == node.key }.map {
      "calls \($0.target) over \($0.kind)"
    }
    let incoming = map.connections.filter { $0.target == node.key }.map {
      "called by \($0.source) over \($0.kind)"
    }
    return ([node.key, node.isService ? "service" : "app"] + outgoing + incoming)
      .joined(separator: ", ")
  }

  /// VoiceOver text for a connection label.
  func description(_ edge: Edge, docs: String?) -> String {
    let count = docs.map { $0 == "1" ? "1 doc" : "\($0) docs" } ?? "docs not loaded"
    return "\(edge.connection.source) calls \(edge.connection.target) over "
      + "\(edge.connection.kind), \(count)"
  }
}
