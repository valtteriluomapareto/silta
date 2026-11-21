import SiltaAppSupport
import SwiftUI

struct AppScreenToolbar: ToolbarContent {
  @Bindable var model: AppModel
  @Binding var searchFocused: Bool
  let compactSearch: Bool

  var body: some ToolbarContent {
    // With the title removed, the controls sit at the leading edge without this; the
    // design keeps them at the window's trailing edge.
    ToolbarSpacer(.flexible, placement: .primaryAction)
    if model.route == .docs {
      ToolbarItem(placement: .primaryAction) { documentTabs }
        .sharedBackgroundVisibility(.hidden)
    }
    if model.route == .workspace {
      ToolbarItem(placement: .primaryAction) {
        SeaSegments(
          label: "Workspace view", options: [(.map, "Map"), (.list, "List")],
          selection: $model.workspaceView
        ).frame(width: 130)
      }.sharedBackgroundVisibility(.hidden)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      if model.route == .board { BoardFilterMenu(model: model) }
      if model.route == .docs {
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
    ToolbarItem(placement: .primaryAction) {
      if compactSearch && !searchFocused {
        Button("Search", systemImage: "magnifyingglass") { searchFocused = true }
          .labelStyle(.iconOnly)
      } else {
        ToolbarSearchField(
          text: $model.search, focused: $searchFocused,
          prompt: model.route == .docs ? "Search loaded documents" : "Search"
        )
        .frame(width: 220)
      }
    }
    if model.route == .board || model.route == .workspace {
      ToolbarSpacer(.fixed, placement: .primaryAction)
      ToolbarItem(placement: .primaryAction) {
        Button("Inspector", systemImage: "sidebar.right") { model.toggleInspector() }
          .labelStyle(.iconOnly).help("Toggle inspector (⌥⌘I)")
      }
    }
  }

  private var documentTabs: some View {
    SeaSegments(
      label: "View",
      options: AppDocumentView.allCases.map { ($0, $0.rawValue.capitalized) },
      selection: Binding(get: { model.documents.view }, set: { model.select(documentView: $0) })
    ).frame(width: 260)
  }

}

private struct BoardFilterMenu: View {
  @Bindable var model: AppModel

  var body: some View {
    let apps = model.visibleData?.map?.apps ?? []
    let filter = model.boardFilter
    let counts = model.visibleData?.snapshot.map {
      BoardContent(snapshot: $0, apps: apps, filter: filter, search: model.search).counts
    }
    Menu {
      Section("Show") {
        Toggle(label("Blocked tasks", counts?.blocked), isOn: $model.boardFilter.blocked)
        Toggle(label("Proposed tasks", counts?.proposed), isOn: $model.boardFilter.proposals)
        Toggle(label("Done this week", counts?.done), isOn: $model.boardFilter.done)
      }
      Section("App") {
        Picker("App", selection: $model.boardFilter.app) {
          Text("All apps").tag(String?.none)
          ForEach(apps, id: \.slug) { Text($0.name).tag(Optional($0.slug)) }
        }.pickerStyle(.inline).labelsHidden()
      }
      Divider()
      Button("Reset Filters") { model.resetBoardFilter() }.disabled(filter.isDefault)
    } label: {
      Label(
        filter.title(apps: apps),
        systemImage: !filter.isDefault
          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
      ).labelStyle(.titleAndIcon)
    }.help("Filter the board by status and app")
  }

  private func label(_ title: String, _ count: Int?) -> String {
    count.map { "\(title) (\($0))" } ?? title
  }
}
