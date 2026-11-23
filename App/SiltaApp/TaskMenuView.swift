import AppKit
import SiltaAppSupport
import SwiftUI

extension AppModel {
  /// Runs a context-menu or VoiceOver action. Debug control never comes here, so control
  /// copies never write the pasteboard.
  func run(_ action: TaskMenu.Action) {
    switch action {
    case .inspect(let ref): inspect(task: ref)
    case .copy(let value): _ = CopyValue.writeToPasteboard(value)
    case .filterBoard(let slug): showApp(slug)
    case .showDocs(let ref): openDocuments(about: ref)
    case .reveal(let path): NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
  }

  /// The selected workspace's display name, or its slug.
  var workspaceName: String? {
    workspace.map { slug in visibleData?.workspaces.first { $0.slug == slug }?.name ?? slug }
  }

  /// The menu for a task card or row in the current workspace.
  func menuItems(for task: AppTask) -> [TaskMenu.Item] {
    guard let reader, let workspace, let data = visibleData else { return [] }
    return TaskMenu.items(
      for: task,
      in: TaskMenu.Context(
        reader: reader, workspace: workspace, name: workspaceName ?? workspace,
        existing: data.existingWorktrees, now: data.checkedAt))
  }
}

extension View {
  /// Adds the items as a context menu, followed by `extra`, and the available items as
  /// VoiceOver actions.
  func taskMenu<Extra: View>(
    _ items: [TaskMenu.Item], model: AppModel, @ViewBuilder extra: () -> Extra = { EmptyView() }
  ) -> some View {
    contextMenu {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        if item.separatorBefore { Divider() }
        Button(item.label) { if let action = item.action { model.run(action) } }
          .disabled(item.action == nil)
      }
      extra()
    }
    .accessibilityActions {
      ForEach(Array(TaskMenu.accessibilityActions(items).enumerated()), id: \.offset) { _, item in
        Button(item.title) { if let action = item.action { model.run(action) } }
      }
    }
  }
}
