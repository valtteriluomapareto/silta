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

  enum Availability: Equatable {
    case available(Action)
    case unavailable(reason: String)
  }

  struct Item: Equatable {
    let title: String
    let availability: Availability
    var separatorBefore = false

    var action: Action? {
      if case .available(let action) = availability { action } else { nil }
    }

    /// The menu label: an unavailable item names its reason.
    var label: String {
      if case .unavailable(let reason) = availability { title + " (" + reason + ")" } else { title }
    }
  }

  /// What a task menu reads besides the task.
  struct Context {
    let reader: AppReader
    let workspace: String
    /// The workspace's display name, for the agent prompt.
    let name: String
    /// Recorded worktrees found on this Mac, checked off the main thread at load.
    let existing: Set<String>
    let now: Date
  }

  static func items(for task: AppTask, in context: Context) -> [Item] {
    let (reader, workspace, name) = (context.reader, context.workspace, context.name)
    var items = [
      Item(title: "Open in Inspector", availability: .available(.inspect(task.ref))),
      Item(title: "Copy Ref " + task.ref, availability: .available(.copy(task.ref))),
    ]
    if let prompt = prompt(task, now: context.now) {
      items.append(
        Item(
          title: "Copy Agent Prompt",
          availability: prompt
            ? .available(
              .copy(reader.agentPrompt(task: task.ref, workspace: workspace, name: name)))
            : .unavailable(
              reason: task.claimedBy.map { "claimed by " + ActorPresentation($0).name }
                ?? "not resumable")))
    }
    items.append(
      Item(
        title: "Copy “task show” Command",
        availability: .available(
          .copy(reader.readCommand(task: task.ref, workspace: workspace).text))))
    if let slug = task.app {
      var app = Self.items(forApp: slug)
      app[0].separatorBefore = true
      items += app
    }
    items.append(
      Item(title: "Reveal Worktree", availability: reveal(task, existing: context.existing)))
    return items
  }

  static func items(forApp slug: String) -> [Item] {
    [
      Item(title: "Filter Board to " + slug, availability: .available(.filterBoard(slug))),
      Item(title: "Show Docs About " + slug, availability: .available(.showDocs("app:" + slug))),
    ]
  }

  /// The menu's available items, in order, for VoiceOver's actions rotor.
  static func accessibilityActions(_ items: [Item]) -> [Item] {
    items.filter { $0.action != nil }
  }

  /// Whether a recorded worktree can be revealed, and why not. The inspector uses the same
  /// rule.
  static func reveal(_ task: AppTask, existing: Set<String>) -> Availability {
    guard let path = task.worktree else {
      return .unavailable(
        reason: ["proposed", "todo"].contains(task.status) ? "not claimed" : "no worktree recorded")
    }
    guard path.hasPrefix("/"), existing.contains(path) else {
      return .unavailable(reason: "not on this Mac")
    }
    return .available(.reveal(path))
  }

  /// Nil hides the prompt; false shows it disabled. A todo task can be started, and a Doing
  /// one only when Core lets another agent take it: its claim expired or was released.
  private static func prompt(_ task: AppTask, now: Date) -> Bool? {
    switch task.status {
    case "todo": return true
    case "doing":
      return task.claimExpired(at: now) || (task.claimedBy == nil && task.resumeAvailable)
    default: return nil
    }
  }
}
