import Foundation
import GRDB

extension TaskService {
  /// Returns an explicitly answered batch to todo atomically, regardless of readiness.
  package func unblock(_ refs: [String], why: String? = nil, allowSecret: Bool = false) throws
    -> [TaskResult]
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
      var tasks: [TaskDetails] = []
      for ref in refs {
        let task: TaskDetails
        do { task = try Self.lookup(ref, workspace: slug, in: tx.database) } catch TaskError
          .notFound
        {
          throw TaskReferenceError(ref: ref, missing: true)
        } catch TaskError.invalid { throw TaskReferenceError(ref: ref, missing: false) }
        try validateClaim(task, at: at)
        guard task.status == "blocked" else {
          throw TaskError.transition(task.ref, status: task.status)
        }
        if !tasks.contains(where: { $0.id == task.id }) { tasks.append(task) }
      }
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
      try approval?.record(
        command: command + " --allow-secret", workspace: slug,
        identity: (environment.ids, at), in: tx)
      return tasks.map {
        TaskResult(
          ref: $0.ref, status: "todo",
          warnings: content.1 ? [SecretGuard.warning] : [])
      }
    }
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
