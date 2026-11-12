import Foundation
import GRDB

extension TaskService {
  /// The accepted `--rel` values for task links.
  package static let relations = ["cites", "about", "source", "relates"]

  /// Resolves a concrete reference and inserts an idempotent typed link.
  package func link(_ ref: String, target raw: String, relation: String = "cites") throws
    -> TaskResult
  {
    try validateLink(raw, relation: relation)
    let command = "silta task link " + shellWord(ref) + " '<target>' --rel " + shellWord(relation)
    let content = try linkContent(raw, command: command)
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, workspace: slug, at: at)
      let target = try TaskLinkTarget.resolve(
        content.0, source: task, workspace: slug, in: tx.database)
      let exists =
        try Bool.fetchOne(
          tx.database,
          sql: """
            SELECT EXISTS(SELECT 1 FROM link
              WHERE workspace_id=? AND from_kind='task' AND from_id=? AND rel=? AND to_kind=?
                AND to_id IS ? AND to_ext IS ? AND anchor IS ?)
            """,
          arguments: [
            task.workspaceID, task.id, relation, target.kind,
            target.id, target.external, target.anchor,
          ]) ?? false
      var result = receipt(task, warnings: content.1 ? [SecretGuard.warning] : [])
      result.target = try target.rendered(in: tx.database)
      if exists { return result }
      try tx.database.execute(
        sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,anchor,
            created_by,created_at)
          VALUES(?,?,'task',?,?,?,?,?,?,?,?)
          """,
        arguments: [
          try environment.ids.next(at: at), task.workspaceID, task.id,
          relation, target.kind, target.id, target.external, target.anchor,
          environment.actor.description, Self.timestamp(at),
        ])
      try tx.database.execute(
        sql: """
          UPDATE task
          SET updated_at=?,claimed_at=CASE WHEN claimed_by=? THEN ? ELSE claimed_at END
          WHERE id=?
          """,
        arguments: [Self.timestamp(at), environment.actor.description, Self.timestamp(at), task.id])
      try changed(task.id, kind: "link", body: relation, redacted: content.1, at: at, in: tx)
      return result
    }
  }

  private func validateLink(_ raw: String, relation: String) throws {
    guard Self.relations.contains(relation) else {
      let values = Self.relations.dropLast().joined(separator: ", ")
      throw TaskError.invalid(
        "Use \(values) or \(Self.relations.last ?? ""); blocked_by is reserved.")
    }
    if raw.hasPrefix("edge:") || raw.hasPrefix("service:") {
      throw CommandFailure(
        error: TaskError.invalid(
          "Edge and service targets are unavailable for task links; "
            + "use code: for code in a legacy app."
        ),
        next: ["silta task link --help"])
    }
  }

  private func linkContent(_ raw: String, command: String) throws -> (String, Bool) {
    do { return try checked(raw, allow: false, command: command) } catch let error as SecretError {
      throw CommandFailure(error: error, next: ["silta task link --help"])
    }
  }
}
