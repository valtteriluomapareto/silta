import Foundation
import SiltaAppSupport

/// The context menu of a task card or row, and of a sidebar app. Each available item is
/// also a VoiceOver action; an unavailable one stays in the menu with its reason.
nonisolated enum TaskMenu {
  enum Action: Equatable {
    case inspect(String)
    case copy(String)
    case filterBoard(String)
    /// Narrows Docs to one map reference, such as `app:acme-web`.
    case showDocs(String)
    case reveal(String)
  }

  struct Item: Equatable {
    let title: String
    /// Nil when the item is unavailable; `reason` says why.
    var action: Action?
    var reason: String?
    var separatorBefore = false
  }

  /// Statuses whose task an agent can start or resume from a prompt.
  private static let promptable: Set<String> = ["todo", "doing"]

  static func items(
    for task: AppTask, reader: AppReader, workspace: String, name: String,
    exists: (String) -> Bool
  ) -> [Item] {
    var items = [
      Item(title: "Open in Inspector", action: .inspect(task.ref)),
      Item(title: "Copy Ref " + task.ref, action: .copy(task.ref)),
    ]
    if promptable.contains(task.status) {
      items.append(
        Item(
          title: "Copy Agent Prompt",
          action: .copy(reader.agentPrompt(task: task.ref, workspace: workspace, name: name))))
    }
    items.append(
      Item(
        title: "Copy “task show” Command",
        action: .copy(reader.readCommand(task: task.ref, workspace: workspace).text)))
    if let slug = task.app {
      var app = Self.items(forApp: slug)
      app[0].separatorBefore = true
      items += app
    }
    items.append(reveal(task, exists: exists))
    return items
  }

  static func items(forApp slug: String) -> [Item] {
    [
      Item(title: "Filter Board to " + slug, action: .filterBoard(slug)),
      Item(title: "Show Docs About " + slug, action: .showDocs("app:" + slug)),
    ]
  }

  /// The menu's available items, in order, for VoiceOver's actions rotor.
  static func accessibilityActions(_ items: [Item]) -> [Item] {
    items.filter { $0.action != nil }
  }

  private static func reveal(_ task: AppTask, exists: (String) -> Bool) -> Item {
    let title = "Reveal Worktree"
    guard let path = task.worktree else {
      return Item(
        title: title, reason: task.claimedBy == nil ? "not claimed" : "no worktree recorded")
    }
    guard path.hasPrefix("/"), exists(path) else {
      return Item(title: title, reason: "not on this Mac")
    }
    return Item(title: title, action: .reveal(path))
  }
}
