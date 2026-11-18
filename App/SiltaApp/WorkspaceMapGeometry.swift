import Foundation
import SiltaAppSupport

/// Points for a computed map layout: fixed node sizes, a fixed row pitch and columns
/// centred on the tallest one. The layout never depends on the window size.
nonisolated struct WorkspaceMapGeometry {
  static let appSize = CGSize(width: 176, height: 84)
  static let serviceSize = CGSize(width: 128, height: 58)
  static let columnGap: CGFloat = 136
  static let rowPitch: CGFloat = 112
  static let margin: CGFloat = 32

  let frames: [String: CGRect]
  let size: CGSize

  init(layout: AppMapLayout) {
    let rows = Dictionary(grouping: layout.nodes, by: \.column).mapValues(\.count)
    let tallest = rows.values.max() ?? 0
    var frames: [String: CGRect] = [:]
    for node in layout.nodes {
      let size = node.isService ? Self.serviceSize : Self.appSize
      let x = Self.margin + CGFloat(node.column) * (Self.appSize.width + Self.columnGap)
      let offset = CGFloat(tallest - (rows[node.column] ?? 0)) * Self.rowPitch / 2
      let centre = Self.margin + offset + CGFloat(node.row) * Self.rowPitch + Self.rowPitch / 2
      frames[node.key] = CGRect(
        x: x, y: centre - size.height / 2, width: size.width, height: size.height)
    }
    self.frames = frames
    let width =
      layout.columnCount == 0
      ? 0
      : Self.margin * 2 + CGFloat(layout.columnCount) * Self.appSize.width
        + CGFloat(layout.columnCount - 1) * Self.columnGap
    let below: CGFloat = layout.backEdges.isEmpty ? 0 : Self.rowPitch / 2
    size = CGSize(
      width: width, height: Self.margin * 2 + CGFloat(tallest) * Self.rowPitch + below)
  }

  /// The zoom that fits the whole map in the visible area: never above 1, never below
  /// 0.6; a larger map scrolls at 0.6.
  static func fitScale(content: CGSize, in available: CGSize) -> CGFloat {
    guard content.width > 0, content.height > 0 else { return 1 }
    return max(0.6, min(1, available.width / content.width, available.height / content.height))
  }

  /// One cubic segment of an edge.
  struct Curve: Equatable {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint

    /// The point halfway along the curve.
    var midpoint: CGPoint {
      CGPoint(
        x: (start.x + 3 * control1.x + 3 * control2.x + end.x) / 8,
        y: (start.y + 3 * control1.y + 3 * control2.y + end.y) / 8)
    }

    static func bend(_ start: CGPoint, _ end: CGPoint) -> Curve {
      let bend = max(24, (end.x - start.x) / 2)
      return Curve(
        start: start, control1: CGPoint(x: start.x + bend, y: start.y),
        control2: CGPoint(x: end.x - bend, y: end.y), end: end)
    }

    static func line(_ start: CGPoint, _ end: CGPoint) -> Curve {
      Curve(start: start, control1: start, control2: end, end: end)
    }
  }

  /// The segments of an edge: one curve between neighbouring columns; across skipped
  /// columns, a straight run through the gap between rows closest to the middle; for a back
  /// edge, a curve below both nodes. The middle segment carries the label.
  func route(from source: String, to target: String, back: Bool, lane: Int = 0) -> [Curve] {
    guard let from = frames[source], let to = frames[target] else { return [] }
    if back {
      let start = CGPoint(x: from.midX, y: from.maxY)
      let end = CGPoint(x: to.midX, y: to.maxY)
      let depth = max(start.y, end.y) + Self.rowPitch / 2
      return [
        Curve(
          start: start, control1: CGPoint(x: start.x, y: depth),
          control2: CGPoint(x: end.x, y: depth), end: end)
      ]
    }
    let shift = CGFloat(lane) * 14
    let start = CGPoint(x: from.maxX, y: from.midY + shift)
    let end = CGPoint(x: to.minX, y: to.midY + shift)
    let between = frames.values.filter {
      $0.minX > from.maxX && $0.maxX < to.minX
    }.map { $0.insetBy(dx: -8, dy: -10) }
    guard !between.isEmpty else { return [.bend(start, end)] }
    let goal = (start.y + end.y) / 2
    let candidates =
      [start.y, end.y, goal]
      + between.flatMap { [$0.minY - 4, $0.maxY + 4] }
    let clear = candidates.filter { y in !between.contains { $0.minY < y && y < $0.maxY } }
    let track = clear.min { abs($0 - goal) < abs($1 - goal) } ?? goal
    let entry = CGPoint(x: from.maxX + Self.columnGap / 2, y: track)
    let exit = CGPoint(x: to.minX - Self.columnGap / 2, y: track)
    return [.bend(start, entry), .line(entry, exit), .bend(exit, end)]
  }
}
