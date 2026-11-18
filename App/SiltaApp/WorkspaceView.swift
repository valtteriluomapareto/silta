import SiltaAppSupport
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel

  var body: some View {
    Group {
      if let map = model.visibleData?.map {
        let content = WorkspaceContent(map: map, search: model.search)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(content.groups) { group in
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                  StatusDot(color: appColor(group.app.slug))
                  Text(group.app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .help(group.app.name)
                  Text(group.app.ref).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color("SecondaryInk")).lineLimit(1).help(group.app.ref)
                  if let summary = group.app.summary {
                    Text(summary).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
                      .lineLimit(1).help(summary)
                  }
                  Spacer(minLength: 4)
                  Text(
                    "\(model.visibleData?.snapshot?.board.appOpenCounts[group.app.slug] ?? 0) open"
                  )
                  .font(.system(size: 11)).foregroundStyle(Color("SecondaryInk")).fixedSize()
                  CopyValue(value: group.app.attachment, title: "Copy app reference", compact: true)
                }.padding(.horizontal, 8)
                ForEach(group.connections, id: \.attachment) { connection in
                  let selected = model.workspaceSelection?.connectionRef == connection.attachment
                  Button {
                    model.select(connection: connection.attachment)
                  } label: {
                    HStack(spacing: 12) {
                      Image(systemName: "arrow.right").font(.system(size: 11)).frame(width: 14)
                      Text(connection.target).font(.system(size: 13))
                        .lineLimit(1).frame(width: 130, alignment: .leading).help(connection.target)
                      Text(connection.kind).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).frame(width: 74, alignment: .leading).help(connection.kind)
                      Text(connection.summary).font(.system(size: 12)).foregroundStyle(
                        Color("SecondaryInk")
                      )
                      .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(
                        connection.summary)
                      Text(model.workspaceDocuments.countLabel(for: connection.attachment))
                        .font(.system(size: 11)).foregroundStyle(
                          Color(
                            model.workspaceDocuments.countText(for: connection.attachment) == "0"
                              ? "SecondaryInk" : "TideText")
                        )
                        .frame(width: 55, alignment: .trailing)
                    }.foregroundStyle(selected ? Color("TideText") : Color("Ink"))
                      .padding(.horizontal, 8).padding(.vertical, 8)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .contentShape(.rect)
                      .background(
                        selected
                          ? Color("TideText").opacity(0.12) : .clear, in: .rect(cornerRadius: 7))
                  }.buttonStyle(.plain)
                }
                Divider().padding(.top, 12)
              }
            }
            if content.groups.isEmpty {
              ContentUnavailableView("No matching apps or connections", systemImage: "network")
            }
            if let failure = model.workspaceDocuments.failure {
              Text(failure).font(.system(size: 12)).foregroundStyle(Color("SecondaryInk"))
              Button("Retry documents") { Task { await model.loadWorkspaceDocuments(force: true) } }
            }
          }.padding(24)
        }.inspector(isPresented: $model.workspaceInspectorPresented) {
          ConnectionInspector(
            connection: content.connection(model.workspaceSelection?.connectionRef), model: model
          ).inspectorColumnWidth(min: 300, ideal: 360, max: 500)
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
          Text(connection.source + " → " + connection.target)
            .font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
          CopyValue(value: connection.attachment, title: "Copy connection reference")
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
          documents(connection)
        } else {
          ContentUnavailableView("Select a connection", systemImage: "sidebar.right")
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }.foregroundStyle(Color("Ink"))
  }

  private func documents(_ connection: AppConnection) -> some View {
    let docs = model.workspaceDocuments
    let count = docs.countText(for: connection.attachment)
    return VStack(alignment: .leading, spacing: 8) {
      Text(count.map { "Docs · " + $0 } ?? "Docs").font(.system(size: 12, weight: .semibold))
      ForEach(docs.groups(for: connection.attachment)) { group in
        if let document = group.preferred {
          Button {
            model.openDocument(
              document.ref, view: document.state == "proposed" ? .changes : .document,
              about: connection.attachment)
          } label: {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(
                Color("SecondaryInk"))
              VStack(alignment: .leading, spacing: 3) {
                Text(document.title ?? document.slug).font(.system(size: 13)).lineLimit(2)
                  .help(document.title ?? document.slug)
                Text(DocsContent.row(group)).font(.system(size: 11)).foregroundStyle(
                  Color("TideText"))
              }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 10).padding(.vertical, 6)
              .background(Color("Canvas"), in: .rect(cornerRadius: 8))
              .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color("Ink").opacity(0.1)))
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
      if docs.pages[connection.attachment]?.nextOffset != nil {
        Button("Open all related Docs") { model.openDocuments(about: connection.attachment) }
          .buttonStyle(CompactActionStyle())
      }
      Text("Click a doc to open it in Docs.").font(.system(size: 11)).foregroundStyle(
        Color("SecondaryInk"))
    }
  }
}
