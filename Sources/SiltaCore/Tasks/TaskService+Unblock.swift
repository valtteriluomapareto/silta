import Foundation
import GRDB

extension TaskService {
  /// Returns an answered batch to todo atomically. A batch with a task that isn't ready
  /// (spec §8: every blocker a done task) needs the human's go-ahead, decided inside the
  /// write; one approval row covers the batch.
  package func unblock(_ refs: [String], why: String? = nil, allowSecret: Bool = false) throws
    -> (tasks: [TaskResult], approvalUsed: Bool)
  {
    guard !refs.isEmpty else {
      throw TaskError.invalid("Unblock needs at least one task reference.")
    }
    let command =
      "silta task unblock "
      + refs.map { shellWord(SecretGuard.redacted($0)) }.joined(separator: " ")
    let approval = try approval(required: allowSecret, command: command + " --allow-secret")
    let content = try checked(why ?? "", allow: allowSecret, command: command + " -F <file>")
    let at = environment.clock.now()
    let slug = try selected()
    return try environment.db.write { tx in
      let tasks = try blockedBatch(refs, workspace: slug, at: at, in: tx.database)
      let open = try tasks.compactMap { task -> ActorError.Wait? in
        guard try Self.waiting(task, at: at, in: tx.database)?.ready != true else { return nil }
        let unmet = try Self.unmet(task, in: tx.database)
        return ActorError.Wait(ref: task.ref, open: unmet.open, dropped: unmet.dropped)
      }
      let retry = command + (why == nil ? "" : " -F <file>")
      if !open.isEmpty, !environment.actor.isHuman, approval == nil, approved == nil {
        throw ActorError.notReady(command: retry, actor: environment.actor, waits: open)
      }
      let used = try approval ?? self.approval(required: !open.isEmpty, command: retry)
      for task in tasks {
        try Self.clearBlock(task, in: tx)
        try tx.database.execute(
          sql: """
            UPDATE task
            SET status='todo',claimed_by=NULL,claimed_at=NULL,updated_at=?
            WHERE id=?
            """, arguments: [Self.timestamp(at), task.id])
        try changed(
          task.id, kind: "unblock", body: why == nil ? nil : content.0,
          redacted: content.1, at: at, in: tx)
      }
      try used?.record(
        command: audited(command + (allowSecret ? " --allow-secret" : "")), workspace: slug,
        identity: (environment.ids, at), in: tx)
      let results = tasks.map {
        TaskResult(
          ref: $0.ref, status: "todo",
          warnings: content.1 ? [SecretGuard.warning] : [])
      }
      return (results, used != nil)
    }
  }

  /// The distinct blocked tasks of a batch; the first bad ref fails the whole batch.
  private func blockedBatch(_ refs: [String], workspace: String, at date: Date, in db: Database)
    throws -> [TaskDetails]
  {
    var tasks: [TaskDetails] = []
    for ref in refs {
      let task: TaskDetails
      do { task = try Self.lookup(ref, workspace: workspace, in: db) } catch TaskError.notFound {
        throw TaskReferenceError(ref: ref, missing: true)
      } catch TaskError.invalid { throw TaskReferenceError(ref: ref, missing: false) }
      try validateClaim(task, at: date)
      guard task.status == "blocked" else {
        throw TaskError.transition(task.ref, status: task.status)
      }
      if !tasks.contains(where: { $0.id == task.id }) { tasks.append(task) }
    }
    return tasks
  }

  static func clearBlock(_ task: TaskDetails, in tx: StorageTransaction) throws {
    try tx.database.execute(
      sql: """
        DELETE FROM link
        WHERE workspace_id=? AND from_kind='task' AND from_id=? AND rel='blocked_by'
        """, arguments: [task.workspaceID, task.id])
    try tx.database.execute(
      sql: "UPDATE task SET follow_up_at=NULL WHERE id=?", arguments: [task.id])
  }
}
