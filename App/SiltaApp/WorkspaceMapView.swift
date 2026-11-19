import SiltaAppSupport
import SwiftUI

/// The workspace map on a computed layout. Nodes and connection labels are the hit
/// targets; edges are drawn underneath.
struct WorkspaceMapView: View {
  @Bindable var model: AppModel
  let map: AppWorkspaceMap
  @FocusState private var focused: Bool

  var body: some View {
    let layout = AppMapLayout(map: map)
    let geometry = WorkspaceMapGeometry(layout: layout)
    let content = WorkspaceMapContent(
      map: map, layout: layout, node: model.workspaceNode,
      connection: model.workspaceSelection?.connectionRef, search: model.search)
    GeometryReader { proxy in
      let scale = WorkspaceMapGeometry.fitScale(content: geometry.size, in: proxy.size)
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          edges(content, geometry: geometry)
          ForEach(layout.nodes, id: \.key) { node in
            if let frame = geometry.frames[node.key] {
              nodeButton(node, content: content).frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
          }
          if let point = geometry.shelfLabel {
            Overline("Services · \(map.services.count)").fixedSize()
              .offset(x: point.x, y: point.y).accessibilityAddTraits(.isHeader)
          }
          ForEach(content.edges.filter(content.showsLabel), id: \.connection.attachment) { edge in
            if let point = geometry.route(
              from: edge.connection.source, to: edge.connection.target, back: edge.back,
              lane: edge.lane, lanes: edge.lanes
            ).labelPoint {
              label(edge, content: content).position(point)
            }
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .scaleEffect(scale, anchor: .center)
        .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
      }
    }
    .seaPane()
    .focusable().focused($focused).focusEffectDisabled()
    .onKeyPress(.leftArrow) { move(.left) }
    .onKeyPress(.rightArrow) { move(.right) }
    .onKeyPress(.upArrow) { move(.up) }
    .onKeyPress(.downArrow) { move(.down) }
    .onExitCommand { model.clearWorkspaceSelection() }
    .accessibilityElement(children: .contain).accessibilityLabel("Workspace map")
  }

  private func move(_ direction: AppMapLayout.Direction) -> KeyPress.Result {
    model.moveMapSelection(direction)
    return .handled
  }

  private func edges(_ content: WorkspaceMapContent, geometry: WorkspaceMapGeometry) -> some View {
    Canvas { context, _ in
      for edge in content.edges {
        let curves = geometry.route(
          from: edge.connection.source, to: edge.connection.target, back: edge.back,
          lane: edge.lane, lanes: edge.lanes)
        guard let last = curves.last else { continue }
        var path = Path()
        path.move(to: curves[0].start)
        for curve in curves {
          path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        }
        let style = content.style(edge)
        let color = style == .strong ? Color("AccentColor") : Color("Ink").opacity(0.45)
        let width: CGFloat = style == .strong ? 2.5 : edge.toService ? 1.2 : 1.5
        let stroke = StrokeStyle(
          lineWidth: width, lineCap: .round, dash: edge.back ? [5, 4] : [])
        var layer = context
        layer.opacity =
          switch style {
          case .strong, .normal: 1
          case .quiet: 0.5
          case .faded: edge.toService ? 0.2 : 0.35
          }
        layer.stroke(path, with: .color(color), style: stroke)
        layer.stroke(
          arrowhead(to: last.end, from: last.control2 == last.end ? last.start : last.control2),
          with: .color(color),
          style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
      }
    }.frame(width: geometry.size.width, height: geometry.size.height).allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func arrowhead(to end: CGPoint, from control: CGPoint) -> Path {
    let angle = atan2(end.y - control.y, end.x - control.x)
    var path = Path()
    for side in [-1.0, 1.0] {
      path.move(to: end)
      path.addLine(
        to: CGPoint(
          x: end.x - 7 * cos(angle + side * 0.5), y: end.y - 7 * sin(angle + side * 0.5)))
    }
    return path
  }

  @ViewBuilder private func nodeButton(_ node: AppMapLayout.Node, content: WorkspaceMapContent)
    -> some View
  {
    let selected = model.workspaceNode == node.attachment
    Button {
      model.select(node: node.attachment)
      focused = true
    } label: {
      if node.isService {
        serviceCard(node, callers: content.callers(of: node.key))
      } else if let app = map.apps.first(where: { $0.slug == node.key }) {
        appCard(app)
      }
    }
    .buttonStyle(.plain)
    .overlay {
      if selected {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Color("AccentColor"), lineWidth: 2)
      }
    }
    .background {
      if selected {
        RoundedRectangle(cornerRadius: 19, style: .continuous)
          .fill(Color("AccentColor").opacity(0.14)).padding(-3)
      }
    }
    .opacity(content.isFaded(node.attachment) ? 0.4 : 1)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        if !node.isService { model.showApp(node.key) }
      }
    )
    .accessibilityLabel(content.description(node))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(node.isService ? node.key : "Double-click to open \(node.key) on the Board")
  }

  private func appCard(_ app: AppMapApp) -> some View {
    let claims =
      model.visibleData?.snapshot?.board.doing.filter {
        $0.app == app.slug && $0.claimedBy != nil
      } ?? []
    let open = model.visibleData?.snapshot?.board.appOpenCounts[app.slug] ?? 0
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 3).fill(appColor(app.slug)).frame(width: 8, height: 8)
        Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
      }
      Text(app.ref).font(.system(size: 11, design: .monospaced)).foregroundStyle(
        Color("SecondaryInk")
      ).lineLimit(1)
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        Text("\(open) open").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(claims.prefix(3), id: \.ref) { task in
          ActorLabel(actor: task.claimedBy ?? "").labelStyle(.iconOnly)
        }
      }
    }
    .foregroundStyle(Color("Ink"))
    .padding(.horizontal, 14).padding(.vertical, 11)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .seaCard(radius: 16)
  }

  private func serviceCard(_ node: AppMapLayout.Node, callers: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(String(node.key.dropFirst("service:".count))).font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      Text(callers == 1 ? "1 app" : "\(callers) apps").font(.system(size: 11))
        .foregroundStyle(Color("SecondaryInk"))
    }
    .foregroundStyle(Color("Ink"))
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(Color("Pane").opacity(0.6), in: .rect(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color("Ink").opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
  }

  private func label(_ edge: WorkspaceMapContent.Edge, content: WorkspaceMapContent) -> some View {
    let selected = model.workspaceSelection?.connectionRef == edge.connection.attachment
    let docs = model.workspaceDocuments.countText(for: edge.connection.attachment)
    let text = WorkspaceMapContent.labelText(kind: edge.connection.kind, docs: docs)
    return Button {
      model.select(connection: edge.connection.attachment)
      focused = true
    } label: {
      Text(text).font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(selected ? "TideText" : "SecondaryInk"))
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Color("Card"), in: .capsule)
        .overlay(
          Capsule().strokeBorder(
            selected ? Color("AccentColor") : Color("Ink").opacity(0.12),
            lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .opacity(content.style(edge) == .faded ? 0.4 : 1)
    .simultaneousGesture(
      TapGesture(count: 2).onEnded { model.openDocuments(about: edge.connection.attachment) }
    )
    .accessibilityLabel(content.description(edge, docs: docs))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help("Double-click to open its documents")
  }

  private func appColor(_ slug: String) -> Color {
    Color(SidebarContent.appColor(index: map.apps.firstIndex { $0.slug == slug } ?? 0))
  }
}

extension [WorkspaceMapGeometry.Curve] {
  /// Where an edge's label sits: the middle of its middle segment.
  var labelPoint: CGPoint? { isEmpty ? nil : self[count / 2].midpoint }
}
