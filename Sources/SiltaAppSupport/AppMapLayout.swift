/// A computed, deterministic layout of the workspace map: nothing is stored or dragged.
///
/// Columns follow the calls from left to right. A depth-first walk from apps without
/// callers, in slug order, marks the connections that close a cycle as back edges;
/// columns are the longest path over the remaining edges. Services take one column after
/// the last app column, which the map draws as a row under the apps. Column 0 is ordered
/// by slug; later app columns by the mean row of their distinct callers in earlier
/// columns, then by slug. Services are ordered by the mean column of their distinct
/// callers, then their mean row, then slug, so each sits near the apps that use it.
/// Nodes without callers come last.
public struct AppMapLayout: Equatable, Sendable {
  /// One app or service on the map.
  public struct Node: Equatable, Sendable {
    /// `app:<slug>` or `service:<slug>`, the canonical map reference.
    public let attachment: String
    /// The slug as connections name it: an app slug or `service:<slug>`.
    public let key: String
    /// Zero-based column, left to right.
    public let column: Int
    /// Zero-based row within the column, top to bottom.
    public let row: Int
    /// Whether the node is an external service.
    public let isService: Bool
  }

  /// Nodes in column, then row order.
  public let nodes: [Node]
  /// Connection references drawn as back edges below the nodes.
  public let backEdges: Set<String>
  /// Number of columns, zero for an empty map.
  public let columnCount: Int

  /// Lays out the map's apps, services and connections.
  public init(map: AppWorkspaceMap) {
    let apps = map.apps.map(\.slug).sorted()
    let appSet = Set(apps)
    let edges = map.connections.sorted { $0.attachment < $1.attachment }
    let appEdges = edges.filter { appSet.contains($0.source) && appSet.contains($0.target) }
    var outgoing: [String: [AppConnection]] = [:]
    for edge in appEdges { outgoing[edge.source, default: []].append(edge) }
    for key in outgoing.keys { outgoing[key]?.sort { $0.target < $1.target } }

    let back = Self.backEdges(apps: apps, edges: appEdges, outgoing: outgoing)
    let forward = appEdges.filter { !back.contains($0.attachment) }
    var column = Dictionary(uniqueKeysWithValues: apps.map { ($0, 0) })
    for slug in Self.topologicalOrder(apps: apps, edges: forward) {
      for edge in forward where edge.source == slug {
        column[edge.target] = max(column[edge.target] ?? 0, (column[slug] ?? 0) + 1)
      }
    }
    let serviceColumn = (column.values.max() ?? -1) + 1
    let services = map.services.map(\.key).sorted()
    var attachments = Dictionary(uniqueKeysWithValues: map.apps.map { ($0.slug, $0.attachment) })
    for service in map.services { attachments[service.key] = service.attachment }
    for service in services { column[service] = serviceColumn }

    var callers: [String: Set<String>] = [:]
    for edge in edges where !back.contains(edge.attachment) && column[edge.target] != nil {
      callers[edge.target, default: []].insert(edge.source)
    }
    let keys = apps + services
    let count = keys.isEmpty ? 0 : (column.values.max() ?? 0) + 1
    var row: [String: Int] = [:]
    var ordered: [Node] = []
    for index in 0..<count {
      let members = keys.filter { column[$0] == index }
      let sorted = members.sorted { left, right in
        let lhs = Self.rank(callers[left] ?? [], rows: row, before: index, column: column)
        let rhs = Self.rank(callers[right] ?? [], rows: row, before: index, column: column)
        let services = index == serviceColumn
        let lhsKey = services ? [lhs.column, lhs.row] : [lhs.row]
        let rhsKey = services ? [rhs.column, rhs.row] : [rhs.row]
        return lhsKey == rhsKey ? left < right : lhsKey.lexicographicallyPrecedes(rhsKey)
      }
      for (position, key) in sorted.enumerated() {
        row[key] = position
        let isService = key.hasPrefix("service:")
        ordered.append(
          Node(
            attachment: attachments[key] ?? key, key: key, column: index, row: position,
            isService: isService))
      }
    }
    nodes = ordered
    backEdges = back
    columnCount = count
  }

  /// Finds a node by its connection key: an app slug or `service:<slug>`.
  public func node(_ key: String) -> Node? { nodes.first { $0.key == key } }

  /// A direction for keyboard movement on the map.
  public enum Direction: Sendable { case left, right, up, down }

  /// The node an arrow key moves to. On an app, left and right follow the first caller or
  /// callee in connection order, and up and down stay in the column. On a service, left
  /// and right move along the services row and up goes to the first caller. With nothing
  /// selected, the first node.
  public func neighbour(
    of attachment: String?, _ direction: Direction, connections: [AppConnection]
  ) -> String? {
    guard let attachment, let current = nodes.first(where: { $0.attachment == attachment })
    else { return nodes.first?.attachment }
    let ordered = connections.sorted { $0.attachment < $1.attachment }
    let caller = ordered.first { $0.target == current.key }.flatMap { node($0.source)?.attachment }
    if current.isService {
      switch direction {
      case .up: return caller
      case .down: return nil
      case .left, .right:
        let row = current.row + (direction == .left ? -1 : 1)
        return nodes.first { $0.column == current.column && $0.row == row }?.attachment
      }
    }
    switch direction {
    case .left:
      return caller
    case .right:
      return ordered.first { $0.source == current.key }.flatMap { node($0.target)?.attachment }
    case .up, .down:
      let row = current.row + (direction == .up ? -1 : 1)
      return nodes.first { $0.column == current.column && $0.row == row }?.attachment
    }
  }

  private static func backEdges(
    apps: [String], edges: [AppConnection], outgoing: [String: [AppConnection]]
  ) -> Set<String> {
    let called = Set(edges.map(\.target))
    var visited: Set<String> = []
    var onPath: Set<String> = []
    var back: Set<String> = []
    func walk(_ slug: String) {
      visited.insert(slug)
      onPath.insert(slug)
      for edge in outgoing[slug] ?? [] {
        if onPath.contains(edge.target) {
          back.insert(edge.attachment)
        } else if !visited.contains(edge.target) {
          walk(edge.target)
        }
      }
      onPath.remove(slug)
    }
    for slug in apps where !called.contains(slug) && !visited.contains(slug) { walk(slug) }
    for slug in apps where !visited.contains(slug) { walk(slug) }
    return back
  }

  private static func topologicalOrder(apps: [String], edges: [AppConnection]) -> [String] {
    var incoming = Dictionary(uniqueKeysWithValues: apps.map { ($0, 0) })
    for edge in edges { incoming[edge.target, default: 0] += 1 }
    var ready = apps.filter { incoming[$0] == 0 }
    var order: [String] = []
    while !ready.isEmpty {
      let slug = ready.removeFirst()
      order.append(slug)
      for edge in edges where edge.source == slug {
        incoming[edge.target, default: 0] -= 1
        if incoming[edge.target] == 0 { ready.append(edge.target) }
      }
    }
    return order
  }

  /// The mean column and mean row of a node's callers placed in earlier columns; infinite
  /// for a node without such callers, so it sorts last.
  private static func rank(
    _ callers: Set<String>, rows: [String: Int], before index: Int, column: [String: Int]
  ) -> (column: Double, row: Double) {
    let placed = callers.filter { (column[$0] ?? index) < index }
    let placedRows = placed.compactMap { rows[$0] }
    guard !placedRows.isEmpty else { return (.infinity, .infinity) }
    let columns = placed.compactMap { column[$0] }
    return (
      Double(columns.reduce(0, +)) / Double(columns.count),
      Double(placedRows.reduce(0, +)) / Double(placedRows.count)
    )
  }
}
