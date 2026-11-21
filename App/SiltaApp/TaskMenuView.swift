import AppKit
import SiltaAppSupport
import SwiftUI

extension AppModel {
  /// Runs a context-menu or VoiceOver action.
  func perform(_ action: TaskMenu.Action) {
    switch action {
    case .inspect(let ref): inspect(task: ref)
    case .copy(let value): _ = CopyValue.writeToPasteboard(value)
    case .filterBoard(let slug): showApp(slug)
    case .showDocs(let ref): openDocuments(about: ref)
    case .reveal(let path): NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
  }

  /// The menu for a task card or row in the current workspace.
  func menuItems(for task: AppTask) -> [TaskMenu.Item] {
    guard let reader, let workspace else { return [] }
    let name = visibleData?.workspaces.first { $0.slug == workspace }?.name ?? workspace
    return TaskMenu.items(
      for: task, reader: reader, workspace: workspace, name: name,
      exists: { FileManager.default.fileExists(atPath: $0) })
  }
}

extension View {
  /// Adds the items as a context menu and the available ones as VoiceOver actions.
  func taskMenu(_ items: [TaskMenu.Item], model: AppModel) -> some View {
    contextMenu {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        if item.separatorBefore { Divider() }
        if let action = item.action {
          Button(item.title) { model.perform(action) }
        } else {
          Button(item.title + (item.reason.map { " (\($0))" } ?? "")) {}.disabled(true)
        }
      }
    }
    .accessibilityActions {
      ForEach(Array(TaskMenu.accessibilityActions(items).enumerated()), id: \.offset) { _, item in
        if let action = item.action { Button(item.title) { model.perform(action) } }
      }
    }
  }
}
