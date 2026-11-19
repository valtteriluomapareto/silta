import SiltaAppSupport
import SwiftUI

/// Points for a computed map layout: fixed node sizes, a fixed row pitch and app columns
/// centred on the tallest one. Services sit in one row under the apps, and whichever of
/// the two is narrower is centred on the other. The layout never depends on the window
/// size.
nonisolated struct WorkspaceMapGeometry {
  static let appSize = CGSize(width: 176, height: 84)
  static let serviceSize = CGSize(width: 120, height: 52)
  static let columnGap: CGFloat = 136
  static let rowPitch: CGFloat = 112
  static let margin: CGFloat = 32
  static let laneGap: CGFloat = 14
  /// Vertical room between the apps (and their back edges) and the services row: the
  /// lines down to services bend here.
  static let shelfGap: CGFloat = 120
  static let serviceGap: CGFloat = 12
  /// How far apart the side drops of stacked apps in one column run.
  static let dropPitch: CGFloat = 30

  let frames: [String: CGRect]
  let size: CGSize
  /// Where the services row's overline sits, under the row; nil without services.
  let shelfLabel: CGPoint?
  /// The bottom edge of the lowest app; back edges run below it.
  private let bottom: CGFloat
  /// Where lines to services leave the apps' area: below the back-edge lanes.
  private let floor: CGFloat
  private let services: Set<String>
  private let lastColumn: [String: Bool]

  init(layout: AppMapLayout) {
    let apps = layout.nodes.filter { !$0.isService }
    let serviceNodes = layout.nodes.filter(\.isService)
    let rows = Dictionary(grouping: apps, by: \.column).mapValues(\.count)
    let tallest = rows.values.max() ?? 0
    let columns = (apps.map(\.column).max() ?? -1) + 1
    let appsWidth =
      columns == 0
      ? 0 : CGFloat(columns) * Self.appSize.width + CGFloat(columns - 1) * Self.columnGap
    let row = Self.rowWidth(serviceNodes.count)
    // A single stacked column drops on its right, into room the margin can't hold.
    let trailing = columns == 1 && tallest > 1 ? Self.dropPitch * CGFloat(tallest - 1) : 0
    let inner = max(appsWidth + trailing, row)
    var frames: [String: CGRect] = [:]
    for node in apps {
      let x =
        Self.margin + (inner - appsWidth - trailing) / 2
        + CGFloat(node.column) * (Self.appSize.width + Self.columnGap)
      let offset = CGFloat(tallest - (rows[node.column] ?? 0)) * Self.rowPitch / 2
      let centre = Self.margin + offset + CGFloat(node.row) * Self.rowPitch + Self.rowPitch / 2
      frames[node.key] = CGRect(
        x: x, y: centre - Self.appSize.height / 2, width: Self.appSize.width,
        height: Self.appSize.height)
    }
    bottom = frames.values.map(\.maxY).max() ?? Self.margin
    let below: CGFloat =
      layout.backEdges.isEmpty
      ? 0 : Self.rowPitch / 3 + CGFloat(layout.backEdges.count) * Self.laneGap
    floor = bottom + below + 16
    let appsBottom = columns == 0 ? 0 : Self.margin + CGFloat(tallest) * Self.rowPitch + below
    let shelfTop = columns == 0 ? Self.margin : appsBottom + Self.shelfGap
    let start = Self.margin + (inner - row) / 2
    for node in serviceNodes {
      let x = start + CGFloat(node.row) * (Self.serviceSize.width + Self.serviceGap)
      frames[node.key] = CGRect(origin: CGPoint(x: x, y: shelfTop), size: Self.serviceSize)
    }
    self.frames = frames
    services = Set(serviceNodes.map(\.key))
    lastColumn = Dictionary(
      uniqueKeysWithValues: apps.map { ($0.key, columns > 1 && $0.column == columns - 1) })
    let shelfBottom = shelfTop + Self.serviceSize.height
    shelfLabel = serviceNodes.isEmpty ? nil : CGPoint(x: start, y: shelfBottom + 10)
    let height =
      serviceNodes.isEmpty
      ? (columns == 0 ? 0 : appsBottom + Self.margin)
      : shelfBottom + 24 + Self.margin
    size =
      layout.nodes.isEmpty ? .zero : CGSize(width: inner + Self.margin * 2, height: height)
  }

  private static func rowWidth(_ count: Int) -> CGFloat {
    count == 0
      ? 0 : CGFloat(count) * serviceSize.width + CGFloat(count - 1) * serviceGap
  }

  /// The zoom that fits the whole map in the visible area: never above 1, never below
  /// 0.6; a larger map scrolls at 0.6.
  static func fitScale(content: CGSize, in available: CGSize) -> CGFloat {
    guard content.width > 0, content.height > 0 else { return 1 }
    return max(0.6, min(1, available.width / content.width, available.height / content.height))
  }

  private func serviceRoute(
    from: CGRect, source: String, to: CGRect, lane: Int, lanes: Int
  ) -> [Curve] {
    let end = CGPoint(x: to.midX, y: to.minY)
    func bend(from point: CGPoint) -> Curve {
      let middle = (point.y + end.y) / 2
      return Curve(
        start: point, control1: CGPoint(x: point.x, y: middle),
        control2: CGPoint(x: end.x, y: middle), end: end)
    }
    let slot = CGFloat(lane)
    let spacing = CGFloat(max(lanes - 1, 1))
    let stacked = frames.filter { key, frame in
      !services.contains(key) && key != source && frame.minY >= from.maxY
        && frame.minX < from.maxX && frame.maxX > from.minX
    }.count
    if stacked > 0 {
      // Out of the side's upper half, where no forward, back or self-loop edge meets the
      // app, and down the column gap; apps higher in the column run further out.
      let left = lastColumn[source] == true
      let side = left ? from.minX : from.maxX
      let start = CGPoint(x: side, y: from.midY - 20 - slot * min(6, 18 / spacing))
      let out = 12 + CGFloat(stacked - 1) * Self.dropPitch + slot * min(8, 18 / spacing)
      let gap = CGPoint(x: left ? side - out : side + out, y: start.y)
      let down = CGPoint(x: gap.x, y: floor)
      return [.line(start, gap), .line(gap, down), bend(from: down)]
    }
    let spread = lanes > 1 ? min(20, (from.width - 32) / spacing) : 0
    let x = from.midX + (slot - CGFloat(lanes - 1) / 2) * spread
    let start = CGPoint(x: x, y: from.maxY)
    let down = CGPoint(x: x, y: floor)
    return [.line(start, down), bend(from: down)]
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
  /// edge, a run through the column gaps and below the lowest app, entering the target
  /// from its right; for a self-loop, a small loop to the node's right. An edge to a
  /// service drops from the app's bottom edge, at slot `lane` of `lanes` spread across it,
  /// straight down to below the lowest app and its back edges, then bends into the top
  /// of the service. An app with another app under it leaves from the upper half of its
  /// right side (left in the last column) and drops through the column gap instead. The
  /// middle segment carries the label; for a line to a service, the final bend does.
  func route(
    from source: String, to target: String, back: Bool, lane: Int = 0, lanes: Int = 1
  ) -> [Curve] {
    guard let from = frames[source], let to = frames[target] else { return [] }
    if services.contains(target) {
      return serviceRoute(from: from, source: source, to: to, lane: lane, lanes: lanes)
    }
    if source == target {
      let reach = 44 + CGFloat(lane) * Self.laneGap
      let start = CGPoint(x: from.maxX, y: from.midY - 12)
      let end = CGPoint(x: from.maxX, y: from.midY + 12)
      return [
        Curve(
          start: start, control1: CGPoint(x: start.x + reach, y: start.y - 24),
          control2: CGPoint(x: end.x + reach, y: end.y + 24), end: end)
      ]
    }
    if back {
      // Ports sit below the centre line, where forward edges don't run.
      let port = 24 + CGFloat(lane % 3) * 6
      let offset = CGFloat(min(lane, 4)) * 10
      let start = CGPoint(x: from.minX, y: from.midY + port)
      let out = CGPoint(x: from.minX - Self.columnGap / 2 + 12 + offset, y: start.y)
      let depth = bottom + Self.rowPitch / 3 + CGFloat(lane) * Self.laneGap
      let back = CGPoint(x: to.maxX + Self.columnGap / 2 - 12 - offset, y: depth)
      let end = CGPoint(x: to.maxX, y: to.midY + port)
      return [
        .line(start, out), .line(out, CGPoint(x: out.x, y: depth)),
        .line(
          CGPoint(x: out.x, y: depth), back),
        .line(back, CGPoint(x: back.x, y: end.y)), .line(CGPoint(x: back.x, y: end.y), end),
      ]
    }
    let shift = CGFloat(lane) * Self.laneGap
    let start = CGPoint(x: from.maxX, y: from.midY + shift)
    let end = CGPoint(x: to.minX, y: to.midY + shift)
    let between = frames.filter { key, frame in
      !services.contains(key) && frame.minX > from.maxX && frame.maxX < to.minX
    }.values.map { $0.insetBy(dx: -8, dy: -10) }
    guard !between.isEmpty else { return [.bend(start, end)] }
    let goal = (start.y + end.y) / 2
    let candidates =
      [start.y, end.y, goal]
      + between.flatMap { [$0.minY - 4, $0.maxY + 4] }
    let clear = candidates.filter { y in !between.contains { $0.minY < y && y < $0.maxY } }
    let track = (clear.min { abs($0 - goal) < abs($1 - goal) } ?? goal) + shift
    let entry = CGPoint(x: from.maxX + Self.columnGap / 2, y: track)
    let exit = CGPoint(x: to.minX - Self.columnGap / 2, y: track)
    return [.bend(start, entry), .line(entry, exit), .bend(exit, end)]
  }
}
