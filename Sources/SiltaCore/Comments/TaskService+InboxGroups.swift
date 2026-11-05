import Foundation
import GRDB

extension TaskService {
  func inboxBlocks(_ workspace: Int64, at date: Date, command: String, in db: Database) throws
    -> [InboxItem]
  {
    let today = String(Self.timestamp(date).prefix(10))
    let tasks = try Row.fetchAll(
      db,
      sql: Self.query + """
        \nWHERE task.workspace_id=? AND task.status='blocked' AND task.external_ref IS NULL
        ORDER BY task.id
        """, arguments: [workspace])
    var urgent: [InboxItem] = []
    var groups: [String: [TaskDetails]] = [:]
    for row in tasks {
      var task = TaskDetails(row: row)
      task.waiting = try Self.waiting(task, at: date, in: db)
      guard let waiting = task.waiting else { continue }
      if waiting.ready || !waiting.dropped.isEmpty {
        urgent.append(blockItem([task], kind: waiting.ready ? "ready" : "replan", command: command))
        continue
      }
      guard let day = task.followUpAt, day <= today else { continue }
      let targets = try Self.blockLinks(task, in: db).filter {
        ["ext", "url"].contains($0["to_kind"] as String)
      }.map { try TaskLinkTarget.render($0, in: db) }
      for target in targets.isEmpty ? [task.ref] : targets {
        groups[target, default: []].append(task)
      }
    }
    let due = groups.map { (target: $0.key, tasks: $0.value) }.sorted {
      let left = $0.tasks.compactMap(\.followUpAt).min() ?? ""
      let right = $1.tasks.compactMap(\.followUpAt).min() ?? ""
      if left != right { return left < right }
      if $0.tasks[0].id != $1.tasks[0].id { return $0.tasks[0].id < $1.tasks[0].id }
      return $0.target < $1.target
    }.map { group in
      var item = blockItem(group.tasks, kind: "due", command: command)
      if group.target.hasPrefix("ext:") || group.target.hasPrefix("url:") {
        item.target = SecretGuard.redacted(group.target)
      }
      item.followUpAt = group.tasks.compactMap(\.followUpAt).min()
      return item
    }
    return urgent + due
  }

  private func blockItem(_ tasks: [TaskDetails], kind: String, command: String) -> InboxItem {
    let next =
      kind == "ready"
      ? command + " task unblock " + tasks.map { shellWord($0.ref) }.joined(separator: " ")
      : command + " task ls --status todo"
    return InboxItem(
      kind: kind, next: [next] + tasks.map { command + " task show " + shellWord($0.ref) },
      tasks: tasks.map(InboxTask.init))
  }

  func inboxBacklog(
    _ workspace: Int64, at date: Date, all: Bool, command: String, in db: Database
  ) throws -> [InboxItem] {
    let cutoff = Self.timestamp(date.addingTimeInterval(-14 * 86400))
    let tasks = try Row.fetchAll(
      db,
      sql: Self.query + """
        \nWHERE task.workspace_id=? AND (task.status='proposed' OR task.external_ref IS NOT NULL)
        ORDER BY task.created_at DESC,task.id DESC
        """, arguments: [workspace]
    ).map { TaskDetails(row: $0) }
    let proposals = tasks.filter {
      $0.status == "proposed" && $0.externalRef == nil && (all || $0.createdAt > cutoff)
    }.map { task in
      let accept = command + " task triage --accept " + shellWord(task.ref)
      let drop = command + " task triage --drop " + shellWord(task.ref)
      let actions =
        environment.actor.isHuman
        ? [accept, drop]
        : [
          "ask human: Accept or drop " + task.ref + "? After approval: "
            + accept + " --approved \"<the human's words>\"; or "
            + drop + " --approved \"<the human's words>\""
        ]
      return InboxItem(
        kind: "proposal", ref: task.ref, author: task.createdBy, createdAt: task.createdAt,
        next: actions + [command + " task show " + shellWord(task.ref)], tasks: [InboxTask(task)])
    }
    let promoted = try tasks.filter {
      guard $0.externalRef != nil, !["done", "dropped"].contains($0.status) else { return false }
      return try !Self.isArchived($0, at: date, in: db)
    }.sorted { $0.id < $1.id }.map { task in
      InboxItem(
        kind: "promoted", ref: task.ref,
        next: [command + " task show " + shellWord(task.ref)], tasks: [InboxTask(task)])
    }
    return proposals + promoted
  }
}
