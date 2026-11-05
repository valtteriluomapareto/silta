import Foundation
import GRDB

extension TaskService {
  /// Records what would unblock open work, releases its claim, and sends nothing.
  package func block(_ ref: String, _ input: TaskBlock) throws -> TaskBlockResult {
    let command = input.command(ref)
    let approval = try approval(
      required: input.allowSecret, command: command + " -F <file> --allow-secret")
    let content = try blockContent(input, command: command + " -F <file>")
    var redacted = content.1
    let refs = try input.on.map { raw in
      if TaskBlock.party(raw) != nil { return raw }
      let checked = try checked(raw, allow: input.allowSecret, command: command + " -F <file>")
      redacted = redacted || checked.1
      return checked.0
    }
    let at = environment.clock.now()
    let day = try TaskFollowUp.day(input.followUp, at: at)
    let slug = try selected()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, workspace: slug, at: at)
      guard ["todo", "doing", "review", "blocked"].contains(task.status) else {
        throw TaskError.transition(task.ref, status: task.status)
      }
      let targets = try refs.map {
        try blockTarget($0, task: task, workspace: slug, in: tx.database)
      }
      let known = try Self.knownParties(workspace: task.workspaceID, in: tx.database)
      let newParties = Set(targets.filter { $0.kind == "ext" }.compactMap(\.external)).subtracting(
        known)
      for target in targets { try insertBlock(target, task: task, at: at, in: tx) }
      let on = try Self.blockIdentities(task, in: tx.database)
      try tx.database.execute(
        sql: """
          UPDATE task
          SET status='blocked',follow_up_at=?,claimed_by=NULL,claimed_at=NULL,updated_at=?
          WHERE id=?
          """, arguments: [day, Self.timestamp(at), task.id])
      try changed(
        task.id, kind: "block",
        body: TaskBlockEvent(on: on, followUp: day, why: content.0).encoded(),
        redacted: redacted, at: at, in: tx)
      try approval?.record(
        command: audited(command + " --allow-secret"), workspace: slug,
        identity: (environment.ids, at),
        in: tx)
      let after = try Self.decorate(
        Self.lookup(ref, workspace: slug, in: tx.database), at: at, in: tx.database)
      let warnings =
        Self.partyWarnings(newParties, known: known) + (redacted ? [SecretGuard.warning] : [])
      return TaskBlockResult(
        ref: after.ref, status: after.status, followUpAt: after.followUpAt,
        waiting: after.waiting, warnings: warnings)
    }
  }

  private func blockContent(_ input: TaskBlock, command: String) throws -> (String, Bool) {
    let content = try checked(input.why, allow: input.allowSecret, command: command)
    guard !content.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskError.invalid("Block needs a nonblank reason with -m or -F <file>.")
    }
    return content
  }

  private static func partyWarnings(_ newParties: Set<String>, known: Set<String>)
    -> [OutputWarning]
  {
    newParties.sorted().map {
      OutputWarning(
        code: "new_party",
        message: "New party ext:\($0); known parties: "
          + (known.isEmpty ? "none" : known.sorted().map { "ext:" + $0 }.joined(separator: ", "))
          + ". Silta sends nothing.")
    }
  }

  private static func blockIdentities(_ task: TaskDetails, in db: Database) throws -> [String] {
    try blockLinks(task, in: db).map { row -> String in
      if (row["to_kind"] as String) != "task" {
        return try TaskLinkTarget.render(row, in: db)
      }
      guard
        let uid = try String.fetchOne(
          db, sql: "SELECT uid FROM task WHERE id=?", arguments: [row["to_id"] as Int64])
      else { throw StorageError.corrupt }
      return uid
    }
  }

  private func blockTarget(_ raw: String, task: TaskDetails, workspace: String, in db: Database)
    throws -> TaskLinkTarget
  {
    let target = try Self.blocker(raw, workspace: workspace, in: db)
    if target.kind == "task" {
      guard let id = target.id, id != task.id,
        let status = try String.fetchOne(
          db, sql: "SELECT status FROM task WHERE id=?", arguments: [id]),
        !["done", "dropped"].contains(status)
      else {
        throw TaskError.invalid("A task blocker must be another open task in this workspace.")
      }
    }
    return target
  }

  private func insertBlock(
    _ target: TaskLinkTarget, task: TaskDetails, at: Date, in tx: StorageTransaction
  )
    throws
  {
    let exists =
      try Bool.fetchOne(
        tx.database,
        sql: """
          SELECT EXISTS(SELECT 1 FROM link
            WHERE workspace_id=? AND from_kind='task' AND from_id=? AND rel='blocked_by'
              AND to_kind=? AND to_id IS ? AND to_ext IS ? AND anchor IS NULL)
          """, arguments: [task.workspaceID, task.id, target.kind, target.id, target.external])
      ?? false
    guard !exists else { return }
    try tx.database.execute(
      sql: """
        INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,
          created_by,created_at)
        VALUES(?,?,'task',?,'blocked_by',?,?,?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: at), task.workspaceID, task.id, target.kind,
        target.id, target.external, environment.actor.description, Self.timestamp(at),
      ])
  }

  private static func knownParties(workspace: Int64, in db: Database) throws -> Set<String> {
    let bodies = try String.fetchAll(
      db,
      sql: """
        SELECT task_event.body
        FROM task_event
        JOIN task ON task.id=task_event.task_id
        WHERE task.workspace_id=? AND task_event.kind='block'
        """, arguments: [workspace])
    return try Set(bodies.flatMap { try TaskBlockEvent.decode($0).on.compactMap(TaskBlock.party) })
  }
}
