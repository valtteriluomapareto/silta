import SiltaAppSupport
import SwiftUI

/// The inspector for an app or a service selected on the map.
struct NodeInspector: View {
  let ref: String
  let map: AppWorkspaceMap
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let app = map.apps.first(where: { $0.attachment == ref }) {
          appDetail(app)
        } else if let service = map.services.first(where: { $0.attachment == ref }) {
          header("Service", title: service.name, ref: service.attachment)
          if let summary = service.summary { Text(summary).font(.system(size: 13)) }
          connections(
            "Called by", map.connections.filter { $0.target == service.key },
            incoming: true)
          if service.summary == nil {
            Text("No summary in the workspace YAML.").font(.system(size: 11))
              .foregroundStyle(Color("SecondaryInk"))
          }
          openDocuments(service.attachment)
        } else {
          ContentUnavailableView("Select an app or a service", systemImage: "sidebar.right")
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }.seaPane().foregroundStyle(Color("Ink"))
  }

  @ViewBuilder private func appDetail(_ app: AppMapApp) -> some View {
    header("App", title: app.name, ref: app.attachment)
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 3).fill(Color(model.appColour(app.slug)))
        .frame(width: 10, height: 10).accessibilityHidden(true)
      AppColourMenu(model: model, slug: app.slug).fixedSize().font(.system(size: 12))
    }
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
      fact("Repo", app.repo, monospaced: true)
      fact("Ref", app.ref, monospaced: true)
      if let summary = app.summary { fact("Summary", summary) }
    }.font(.system(size: 12)).textSelection(.enabled)
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color("Ink").opacity(0.03), in: .rect(cornerRadius: 12))
    connections(
      "Connections",
      map.connections.filter { $0.source == app.slug || $0.target == app.slug },
      incoming: false, app: app.slug)
    let work = openWork(app.slug)
    VStack(alignment: .leading, spacing: 6) {
      Overline("Open work · \(work.count)")
      ForEach(work, id: \.ref) { task in
        Button {
          model.inspect(task: task.ref)
        } label: {
          HStack(spacing: 8) {
            Text(task.ref).font(.system(size: 11, design: .monospaced))
              .foregroundStyle(Color("SecondaryInk")).frame(width: 46, alignment: .leading)
            Text(task.title).font(.system(size: 12)).lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(TaskPresentation.mapStatus(task)).font(.system(size: 11))
              .foregroundStyle(Color(task.claimedBy == nil ? "SecondaryInk" : "TideText"))
          }.contentShape(.rect)
        }.buttonStyle(.plain).help(task.title)
      }
      Button("Show on Board") { model.showApp(app.slug) }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color("TideText"))
        .padding(.top, 4)
    }
    openDocuments(app.attachment)
  }

  private func openDocuments(_ ref: String) -> some View {
    Button {
      model.openDocuments(about: ref)
    } label: {
      Text("Open in Docs").font(.system(size: 13, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Color("AccentColor"), in: .capsule).foregroundStyle(Color("Canvas"))
        .contentShape(.capsule)
    }.buttonStyle(.plain).help("Open the documents about \(ref)")
  }

  private func header(_ kind: String, title: String, ref: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Overline(kind)
      Text(title).font(.system(size: 20, weight: .bold)).tracking(-0.2).textSelection(.enabled)
      CopyValue(value: ref, title: "Copy \(kind.lowercased()) reference")
    }
  }

  private func fact(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
    GridRow(alignment: .top) {
      Text(title).foregroundStyle(Color("SecondaryInk"))
      Text(value).font(
        .system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default))
    }
  }

  private func connections(
    _ title: String, _ edges: [AppConnection], incoming: Bool, app: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Overline("\(title) · \(edges.count)")
      ForEach(edges, id: \.attachment) { edge in
        let inbound = incoming || edge.target == app
        Button {
          model.select(connection: edge.attachment)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: inbound ? "arrow.left" : "arrow.right").font(.system(size: 11))
              .foregroundStyle(Color("TideText")).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
              Text(map.endpointName(inbound ? edge.source : edge.target)).font(.system(size: 13))
              Text(
                WorkspaceMapContent.labelText(
                  kind: edge.kind, docs: model.workspaceDocuments.countText(for: edge.attachment))
              ).font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color("Card"), in: .rect(cornerRadius: 10)).contentShape(.rect)
        }.buttonStyle(.plain)
          .accessibilityLabel(
            inbound
              ? "\(map.endpointName(edge.source)) calls \(map.endpointName(edge.target)) over "
                + edge.kind
              : "Calls \(map.endpointName(edge.target)) over \(edge.kind)")
      }
    }
  }

  private func openWork(_ slug: String) -> [AppTask] {
    guard let board = model.visibleData?.snapshot?.board else { return [] }
    return (board.doing + board.review + board.todo).filter { $0.app == slug }
  }
}
