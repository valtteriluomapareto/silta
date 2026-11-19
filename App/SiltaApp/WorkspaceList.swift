import SiltaAppSupport
import SwiftUI

/// The Workspace list: flat app rows in call order. A closed row shows the app, its open
/// count and the services it uses; opening it adds who calls it, what it calls and how it
/// uses each service. The services follow, most shared first.
struct WorkspaceList: View {
  @Bindable var model: AppModel
  let map: AppWorkspaceMap
  let content: WorkspaceContent
  @State private var open: Set<String> = []
  @State private var showFolded = false

  private static let appWidth: CGFloat = 228
  private static let openWidth: CGFloat = 40
  private static let usesInset: CGFloat = 24

  var body: some View {
    let selected = model.workspaceNode.flatMap { ref in map.nodeKey(for: ref) }
    let related = content.related(to: selected)
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        header
        ForEach(content.apps) { row in
          let isSelected = selected == row.id
          VStack(alignment: .leading, spacing: 0) {
            appRow(row, selected: isSelected)
            if open.contains(row.id) { details(row) }
          }
          .background(
            Color("AccentColor").opacity(
              isSelected ? 0.10 : related.contains(row.id) ? 0.04 : 0),
            in: .rect(cornerRadius: 10)
          ).padding(.vertical, 1)
        }
        if content.apps.isEmpty && content.shared.isEmpty {
          ContentUnavailableView("No matching apps or services", systemImage: "network")
        }
        services(selected: selected)
        if let failure = model.workspaceDocuments.failure {
          VStack(alignment: .leading, spacing: 6) {
            Text(failure).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
            Button("Retry documents") {
              Task { await model.loadWorkspaceDocuments(force: true) }
            }
          }.padding(16)
        }
      }.padding(8).padding(.bottom, 16)
    }.seaPane().padding(.bottom, 12)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Overline("Apps · in call order").frame(width: Self.appWidth, alignment: .leading)
      Text("Open").frame(width: Self.openWidth, alignment: .trailing)
      Text("Uses").padding(.leading, Self.usesInset)
      Spacer(minLength: 0)
    }.font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
      .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
      .accessibilityHidden(true)
  }

  private func appRow(_ row: WorkspaceContent.AppRow, selected: Bool) -> some View {
    let isOpen = open.contains(row.id)
    let count = model.visibleData?.snapshot?.board.appOpenCounts[row.id] ?? 0
    return Button {
      // The first click selects the row and opens it; later clicks fold and unfold it.
      if !selected {
        model.select(node: row.app.attachment)
        open.insert(row.id)
      } else if isOpen {
        open.remove(row.id)
      } else {
        open.insert(row.id)
      }
    } label: {
      HStack(spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color("SecondaryInk"))
            .frame(width: 16)
          RoundedRectangle(cornerRadius: 3).fill(appColor(row.id)).frame(width: 8, height: 8)
          Text(row.app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Text(row.app.ref).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color("SecondaryInk")).lineLimit(1)
        }.frame(width: Self.appWidth, alignment: .leading)
        Text("\(count)").font(.system(size: 12))
          .foregroundStyle(Color(count == 0 ? "SecondaryInk" : "Ink"))
          .frame(width: Self.openWidth, alignment: .trailing)
        uses(row.services).padding(.leading, Self.usesInset)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16).frame(height: 44).contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Self.description(row, open: count))
    .accessibilityValue(isOpen ? "expanded" : "collapsed")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(row.app.summary ?? row.app.name)
  }

  @ViewBuilder private func uses(_ services: [String]) -> some View {
    if services.isEmpty {
      Text("No services").font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
    } else {
      HStack(spacing: 5) {
        ForEach(services.prefix(6), id: \.self) { service in
          Text(service).font(.system(size: 11)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color("Ink").opacity(0.05), in: .rect(cornerRadius: 6))
        }
        if services.count > 6 {
          Text("+\(services.count - 6)").font(.system(size: 11))
        }
      }.foregroundStyle(Color("SecondaryInk"))
    }
  }

  private func details(_ row: WorkspaceContent.AppRow) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        if let summary = row.app.summary {
          Text(summary).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          Button("Open documents") { model.openDocuments(about: row.app.attachment) }
            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color("TideText"))
          CopyValue(value: row.app.attachment, title: "Copy app reference", compact: true)
        }
      }.padding(.leading, 24).frame(width: Self.appWidth, alignment: .leading)
      Spacer().frame(width: Self.openWidth + Self.usesInset - 12)
      // The groups wrap under each other when the inspector leaves little room.
      FlowLayout(spacing: 32, lineSpacing: 14) {
        group("Called by", edges: row.calledBy) { $0.source }
        group("Calls", edges: row.calls) { $0.target }
        VStack(alignment: .leading, spacing: 6) {
          Overline("Uses")
          if row.uses.isEmpty {
            Text("No services").font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
          }
          FlowLayout(spacing: 6) {
            ForEach(row.uses, id: \.attachment) { edge in
              connectionButton(
                edge,
                name: map.services.first { $0.key == edge.target }?.name
                  ?? String(edge.target.dropFirst("service:".count))
              )
              .padding(.horizontal, 8).padding(.vertical, 3)
              .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(
                  Color("Ink").opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
  }

  private func group(
    _ title: String, edges: [AppConnection], app: @escaping (AppConnection) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Overline(title)
      if edges.isEmpty {
        Text("None").font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
      }
      ForEach(edges, id: \.attachment) { edge in
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2).fill(appColor(app(edge))).frame(width: 7, height: 7)
          connectionButton(edge, name: app(edge))
        }
      }
    }.fixedSize()
  }

  /// A connection as a button that selects it: the other end's name, its kind and, when
  /// it has any, its doc count.
  private func connectionButton(_ edge: AppConnection, name: String) -> some View {
    let selected = model.workspaceSelection?.connectionRef == edge.attachment
    let docs = model.workspaceDocuments.countText(for: edge.attachment)
    let label = WorkspaceMapContent.labelText(kind: edge.kind, docs: docs)
    return Button {
      model.select(connection: edge.attachment)
    } label: {
      HStack(spacing: 6) {
        Text(name).font(.system(size: 12)).lineLimit(1)
        Text(edge.kind).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(Color("SecondaryInk")).lineLimit(1)
        if let docs, docs != "0" {
          Text(docs == "1" ? "1 doc" : docs + " docs").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color("TideText")).lineLimit(1)
        }
      }.foregroundStyle(Color(selected ? "TideText" : "Ink")).contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(edge.source) calls \(edge.target) over \(label)")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help(edge.summary.isEmpty ? edge.attachment : edge.summary)
  }

  @ViewBuilder private func services(selected: String?) -> some View {
    if !content.shared.isEmpty {
      Overline("Services · most shared first").padding(.horizontal, 16)
        .padding(.top, 22).padding(.bottom, 6)
      ForEach(content.shared) { row in serviceRow(row, selected: selected) }
      if !content.folded.isEmpty {
        Button {
          showFolded.toggle()
        } label: {
          HStack(spacing: 12) {
            Image(systemName: showFolded ? "chevron.down" : "chevron.right")
              .font(.system(size: 11, weight: .semibold)).frame(width: 16)
            Text(Self.foldedTitle(content.folded)).font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color("TideText"))
            if !showFolded {
              Text(content.folded.map(\.id).joined(separator: ", ")).font(.system(size: 12))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }.foregroundStyle(Color("SecondaryInk")).padding(.horizontal, 16).frame(height: 38)
            .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityValue(showFolded ? "expanded" : "collapsed")
        if showFolded {
          ForEach(content.folded) { row in serviceRow(row, selected: selected) }
        }
      }
    }
  }

  private func serviceRow(_ row: WorkspaceContent.ServiceRow, selected: String?) -> some View {
    let isSelected = selected == row.service.key
    return HStack(spacing: 12) {
      Button {
        model.select(node: row.service.attachment)
      } label: {
        HStack(spacing: 12) {
          RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
              Color("Ink").opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])
            )
            .frame(width: 14, height: 14)
          Text(row.service.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            .frame(width: 110, alignment: .leading)
          Text(row.apps == 1 ? "1 app" : "\(row.apps) apps").font(.system(size: 12))
            .foregroundStyle(Color("SecondaryInk")).frame(width: 56, alignment: .leading)
        }.contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      HStack(spacing: 6) {
        ForEach(row.users, id: \.attachment) { edge in
          HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(appColor(edge.source)).frame(width: 7, height: 7)
            connectionButton(edge, name: edge.source)
          }
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(Color("Card").opacity(0.7), in: .rect(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color("Ink").opacity(0.08)))
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16).frame(minHeight: 38)
    .background(
      Color("AccentColor").opacity(isSelected ? 0.10 : 0), in: .rect(cornerRadius: 10))
  }
}

extension WorkspaceList {
  fileprivate func appColor(_ slug: String) -> Color {
    Color(SidebarContent.appColor(index: map.apps.firstIndex { $0.slug == slug } ?? 0))
  }

  static func foldedTitle(_ rows: [WorkspaceContent.ServiceRow]) -> String {
    rows.allSatisfy { $0.apps == 1 }
      ? "\(rows.count) more used by one app" : "\(rows.count) more used by one app or none"
  }

  static func description(_ row: WorkspaceContent.AppRow, open: Int) -> String {
    let uses = row.services.isEmpty ? "no services" : "uses " + row.services.joined(separator: ", ")
    return "\(row.app.name), \(open) open, \(uses)"
  }
}

extension AppWorkspaceMap {
  /// The connection key of a map node reference: an app slug or `service:<slug>`.
  func nodeKey(for attachment: String) -> String? {
    if let app = apps.first(where: { $0.attachment == attachment }) { return app.slug }
    return services.first { $0.attachment == attachment }?.key
  }
}

/// Lays children out left to right, wrapping onto new lines. Each child is offered the
/// container's width, so a child that wraps itself stays inside it.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = arrange(subviews, width: proposal.width ?? .infinity)
    let width = lines.map(\.width).max() ?? 0
    let height =
      lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    let offer = Self.offer(bounds.width)
    for line in arrange(subviews, width: bounds.width) {
      var x = bounds.minX
      for index in line.indices {
        let size = subviews[index].sizeThatFits(offer)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += line.height + lineSpacing
    }
  }

  private static func offer(_ width: CGFloat) -> ProposedViewSize {
    ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
  }

  private struct Line {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
    var lines: [Line] = []
    var line = Line()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(Self.offer(width))
      let added = line.indices.isEmpty ? size.width : line.width + spacing + size.width
      if added > width, !line.indices.isEmpty {
        lines.append(line)
        line = Line()
      }
      line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
      line.height = max(line.height, size.height)
      line.indices.append(index)
    }
    if !line.indices.isEmpty { lines.append(line) }
    return lines
  }
}
