import SiltaAppSupport
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel

  var body: some View {
    Group {
      if let map = model.visibleData?.map {
        let content = WorkspaceContent(map: map, search: model.search)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(content.groups) { group in
              VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(group.app.name).font(.headline)
                    Text(group.app.ref).font(.system(.caption, design: .monospaced))
                    if let summary = group.app.summary { Text(summary).foregroundStyle(.secondary) }
                    Button("Open related Docs") { model.openDocuments(about: group.app.attachment) }
                  }
                  Spacer()
                  Text(
                    "\(model.visibleData?.snapshot?.board.appOpenCounts[group.app.slug] ?? 0) open"
                  )
                  .font(.caption).foregroundStyle(.secondary)
                  CopyValue(value: group.app.attachment, title: "Copy app reference")
                }
                ForEach(group.connections, id: \.attachment) { connection in
                  Button {
                    model.select(connection: connection.attachment)
                  } label: {
                    HStack(alignment: .top, spacing: 12) {
                      Image(systemName: "arrow.right")
                      VStack(alignment: .leading, spacing: 6) {
                        Text(connection.target).font(.body.weight(.medium))
                        Text(connection.summary).font(.callout).foregroundStyle(.secondary)
                      }
                      Spacer()
                      Text(connection.kind).font(.system(.caption, design: .monospaced))
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                      .background(
                        model.workspaceSelection?.connectionRef == connection.attachment
                          ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
                  }.buttonStyle(.plain)
                }
                Divider()
              }
            }
            if !content.services.isEmpty {
              Text("Services").font(.headline)
              ForEach(content.services, id: \.slug) { service in
                HStack {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(service.name).font(.body.weight(.medium))
                    if let summary = service.summary { Text(summary).foregroundStyle(.secondary) }
                  }
                  Spacer()
                  CopyValue(value: service.attachment, title: "Copy service reference")
                }
              }
            }
            if content.groups.isEmpty && content.services.isEmpty {
              ContentUnavailableView("No matching apps or services", systemImage: "network")
            }
          }.padding(28)
        }.inspector(isPresented: $model.workspaceInspectorPresented) {
          ConnectionInspector(
            connection: content.connection(model.workspaceSelection?.connectionRef),
            openDocs: model.openDocuments
          )
          .inspectorColumnWidth(min: 300, ideal: 360, max: 500)
        }
      } else {
        ContentUnavailableView("No workspace map", systemImage: "network")
      }
    }
  }
}

struct ConnectionInspector: View {
  let connection: AppConnection?
  let openDocs: (String) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let connection {
          Text(connection.source + " → " + connection.target).font(.title3.weight(.semibold))
          CopyValue(value: connection.attachment, title: "Copy connection reference")
          Button("Open related Docs") { openDocs(connection.attachment) }
          LabeledContent("Kind", value: connection.kind)
          Text(connection.summary).textSelection(.enabled)
          Text("Code references").font(.headline)
          if connection.codeReferences.isEmpty {
            Text("None recorded").foregroundStyle(.secondary)
          }
          ForEach(connection.codeReferences, id: \.self) { ref in
            HStack {
              Text(ref).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
              Spacer()
              CopyValue(value: ref, title: "Copy code reference", compact: true)
            }
          }
        } else {
          ContentUnavailableView("Select a connection", systemImage: "sidebar.right")
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
