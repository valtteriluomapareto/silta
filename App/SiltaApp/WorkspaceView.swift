import SiltaAppSupport
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel
  @AppStorage(SeaInspectorMetrics.storageKey) private var inspectorWidth = SeaInspectorMetrics.width

  var body: some View {
    Group {
      if let map = model.visibleData?.map {
        let content = WorkspaceContent(map: map, search: model.search)
        Group {
          if model.workspaceView == .map {
            WorkspaceMapView(model: model, map: map).padding(.bottom, 12)
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(content.groups) { group in
                  VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                      Button {
                        model.openDocuments(about: group.app.attachment)
                      } label: {
                        HStack(spacing: 8) {
                          RoundedRectangle(cornerRadius: 3).fill(appColor(group.app.slug))
                            .frame(width: 8, height: 8).accessibilityHidden(true)
                          Text(group.app.name).font(.system(size: 14, weight: .semibold)).lineLimit(
                            1
                          )
                          .help(group.app.name)
                          Text(group.app.ref).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color("SecondaryInk")).lineLimit(1).help(group.app.ref)
                          if let summary = group.app.summary {
                            Text(summary).font(.system(size: 12)).foregroundStyle(
                              Color("SecondaryInk")
                            )
                            .lineLimit(1).help(summary)
                          }
                          Spacer(minLength: 4)
                          Text(
                            "\(model.visibleData?.snapshot?.board.appOpenCounts[group.app.slug] ?? 0) open"
                          )
                          .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
                          .fixedSize()
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                      }.buttonStyle(.plain).help("Open documents for \(group.app.name)")
                      CopyValue(
                        value: group.app.attachment, title: "Copy app reference", compact: true)
                    }.padding(.horizontal, 8)
                    ForEach(group.connections, id: \.attachment) { connection in
                      let selected =
                        model.workspaceSelection?.connectionRef == connection.attachment
                      Button {
                        model.select(connection: connection.attachment)
                      } label: {
                        HStack(spacing: 12) {
                          Image(systemName: "arrow.right").font(.system(size: 11)).frame(width: 14)
                          Text(connection.target).font(.system(size: 13))
                            .lineLimit(1).frame(width: 130, alignment: .leading).help(
                              connection.target)
                          Text(connection.kind).font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).frame(width: 74, alignment: .leading).help(
                              connection.kind)
                          Text(connection.summary).font(.system(size: 12)).foregroundStyle(
                            Color("SecondaryInk")
                          )
                          .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(
                            connection.summary)
                          Text(model.workspaceDocuments.countLabel(for: connection.attachment))
                            .font(.system(size: 11)).foregroundStyle(
                              Color(
                                model.workspaceDocuments.countText(for: connection.attachment)
                                  == "0"
                                  ? "SecondaryInk" : "TideText")
                            )
                            .frame(width: 55, alignment: .trailing)
                        }.foregroundStyle(selected ? Color("TideText") : Color("Ink"))
                          .padding(.horizontal, 8).padding(.vertical, 8)
                          .frame(maxWidth: .infinity, alignment: .leading)
                          .contentShape(.rect)
                          .background(
                            selected
                              ? Color("AccentColor").opacity(0.08) : .clear,
                            in: .rect(cornerRadius: 10)
                          )
                      }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                  }.padding(14).seaPane()
                }
                if content.groups.isEmpty {
                  ContentUnavailableView("No matching apps or connections", systemImage: "network")
                }
                if let failure = model.workspaceDocuments.failure {
                  Text(failure).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
                  Button("Retry documents") {
                    Task { await model.loadWorkspaceDocuments(force: true) }
                  }
                }
              }.padding(.bottom, 24)
            }
          }
        }.seaInspector(isPresented: model.workspaceInspectorPresented, width: $inspectorWidth) {
          Group {
            if let node = model.workspaceNode {
              NodeInspector(ref: node, map: map, model: model)
            } else {
              ConnectionInspector(
                connection: content.connection(model.workspaceSelection?.connectionRef),
                model: model)
            }
          }
        }
      } else {
        ContentUnavailableView("No workspace map", systemImage: "network")
      }
    }.foregroundStyle(Color("Ink"))
      .task(id: "\(model.workspace ?? "")|\(model.visibleData?.version ?? 0)") {
        await model.loadWorkspaceDocuments()
      }
  }

  private func appColor(_ slug: String) -> Color {
    let index = model.visibleData?.map?.apps.firstIndex { $0.slug == slug } ?? 0
    return Color(SidebarContent.appColor(index: index))
  }
}

struct ConnectionInspector: View {
  let connection: AppConnection?
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let connection {
          VStack(alignment: .leading, spacing: 6) {
            Overline("Connection")
            Text(connection.source + " → " + connection.target)
              .font(.system(size: 20, weight: .bold)).tracking(-0.2).textSelection(.enabled)
            CopyValue(value: connection.attachment, title: "Copy connection reference")
          }
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow(alignment: .top) {
              Text("Kind").foregroundStyle(Color("SecondaryInk"))
              Text(connection.kind).font(.system(size: 11, design: .monospaced))
            }
            GridRow(alignment: .top) {
              Text("Summary").foregroundStyle(Color("SecondaryInk"))
              Text(connection.summary)
            }
            GridRow(alignment: .top) {
              Text("Code").foregroundStyle(Color("SecondaryInk"))
              VStack(alignment: .leading, spacing: 6) {
                if connection.codeReferences.isEmpty {
                  Text("None recorded").foregroundStyle(Color("SecondaryInk"))
                }
                ForEach(connection.codeReferences, id: \.self) { ref in
                  HStack {
                    Text(ref).font(.system(size: 11, design: .monospaced))
                    Spacer(minLength: 4)
                    CopyValue(value: ref, title: "Copy code reference", compact: true)
                  }
                }
              }
            }
          }.font(.system(size: 12)).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("Ink").opacity(0.03), in: .rect(cornerRadius: 12))
          documents(connection)
        } else {
          ContentUnavailableView("Select a connection", systemImage: "sidebar.right")
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }.seaPane().foregroundStyle(Color("Ink"))
  }

  private func documents(_ connection: AppConnection) -> some View {
    let docs = model.workspaceDocuments
    let count = docs.countText(for: connection.attachment)
    return VStack(alignment: .leading, spacing: 8) {
      Overline(count.map { "Docs · " + $0 } ?? "Docs")
      ForEach(docs.groups(for: connection.attachment)) { group in
        if let document = group.preferred {
          Button {
            model.openDocument(
              document.ref, view: document.state == "proposed" ? .changes : .document,
              about: connection.attachment)
          } label: {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(
                Color("SecondaryInk"))
              VStack(alignment: .leading, spacing: 2) {
                Text(document.title ?? document.slug).font(.system(size: 13, weight: .semibold))
                  .lineLimit(2).help(document.title ?? document.slug)
                Text(DocsContent.row(group)).font(.system(size: 11))
                  .foregroundStyle(Color("SecondaryInk"))
              }.frame(maxWidth: .infinity, alignment: .leading)
              documentState(group)
            }.padding(.horizontal, 10).padding(.vertical, 8)
              .contentShape(.rect)
          }.buttonStyle(.plain)
        }
      }
      if count == "0" {
        Text("No related documents").font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
      }
      if docs.loading { ProgressView("Loading documents…").controlSize(.small) }
      if let failure = docs.failure {
        Text(failure).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
        Button("Retry") { Task { await model.loadWorkspaceDocuments(force: true) } }
      }
      Spacer(minLength: 12)
      if count != nil && count != "0" && docs.failure == nil {
        openButton(connection, all: docs.pages[connection.attachment]?.nextOffset != nil)
      }
    }
  }

  private func openButton(_ connection: AppConnection, all: Bool) -> some View {
    Button {
      model.openDocuments(about: connection.attachment)
    } label: {
      Text(all ? "Open all in Docs" : "Open in Docs").font(.system(size: 13, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Color("AccentColor"), in: .capsule).foregroundStyle(Color("Canvas"))
        .contentShape(.capsule)
    }.buttonStyle(.plain).help("Open the documents about this connection")
  }

  @ViewBuilder private func documentState(_ group: DocsModel.Group) -> some View {
    let proposals = group.entries.filter { $0.state == "proposed" }
    if let proposal = proposals.first {
      HStack(spacing: 6) {
        StatusDot(color: Color("Warning"))
        Text("@\(proposal.revision) proposed").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color("Warning"))
      }.fixedSize()
    } else {
      HStack(spacing: 6) {
        StatusDot(color: Color("Success"))
        Text("Current").font(.system(size: 11)).foregroundStyle(Color("SecondaryInk"))
      }.fixedSize()
    }
  }
}
