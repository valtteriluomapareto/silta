import SiltaAppSupport
import SwiftUI

struct AppScreenToolbar: ToolbarContent {
  @Bindable var model: AppModel

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if model.route == .board { BoardAppMenu(model: model) }
      if model.route == .docs {
        Picker(
          "View",
          selection: Binding(get: { model.documents.view }, set: { model.select(documentView: $0) })
        ) {
          ForEach(AppDocumentView.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.pickerStyle(.segmented).frame(width: 240)
        if let document = model.documents.document {
          Picker(
            "Revision",
            selection: Binding(get: { model.documents.ref }, set: { model.select(document: $0) })
          ) {
            if !model.documents.versions.contains(where: { $0.ref == document.ref }) {
              Text("@\(document.revision) · \(document.state)").tag(Optional(document.ref))
            }
            ForEach(model.documents.versions, id: \.ref) {
              Text("@\($0.revision) · \($0.state)").tag(Optional($0.ref))
            }
          }.frame(width: 150)
        }
      }
    }
    DefaultToolbarItem(kind: .search, placement: .primaryAction)
    if model.route == .board || model.route == .workspace {
      ToolbarItem(placement: .primaryAction) {
        Button("Inspector", systemImage: "sidebar.right") { model.toggleInspector() }
          .labelStyle(.iconOnly).help("Toggle inspector (⌥⌘I)")
      }
    }
  }
}

private struct BoardAppMenu: View {
  @Bindable var model: AppModel

  var body: some View {
    let apps = model.visibleData?.map?.apps ?? []
    let menu = BoardMenuContent(
      app: model.appFilter, apps: apps,
      proposals: model.visibleData?.snapshot?.board.proposals ?? [],
      showing: model.showProposed)
    Menu {
      Picker("App", selection: $model.appFilter) {
        Text("All apps").tag(String?.none)
        ForEach(apps, id: \.slug) { Text($0.name).tag(Optional($0.slug)) }
      }.pickerStyle(.inline).labelsHidden()
      Divider()
      Toggle("Show proposed tasks (\(menu.proposedCount))", isOn: $model.showProposed)
    } label: {
      Text(menu.title)
    }.help("Filter apps and proposed tasks")
  }
}
