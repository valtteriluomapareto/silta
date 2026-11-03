import Foundation
import GRDB

extension TaskService {
  /// Edits a snapshot, then rechecks content, promotion and the current claim before writing.
  /// A nil callback result cancels without writing or recording approval.
  package func edit(
    _ ref: String, allowSecret: Bool = false, input: (String) throws -> String?
  ) throws -> (result: TaskResult, approvalUsed: Bool) {
    let command =
      "silta task edit " + shellWord(ref)
      + (allowSecret ? " --allow-secret" : "")
    let before = try show(ref)
    try validateClaim(before, at: environment.clock.now())
    let needed = allowSecret || before.claimedBy != environment.actor.description
    _ = try approval(required: needed, command: command + " -F <file>")
    let original = TaskEditDocument(before)
    guard let text = try input(original.render()) else { return (receipt(before), false) }
    let parsed = try TaskEditDocument.parse(text, from: before)
    let safe = try parsed.values.map {
      try checked($0, allow: allowSecret, command: command + " -F <file>")
    }
    let content = safeDocument(safe.map(\.0), from: before)
    let redacted = safe.contains { $0.1 }
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      let required = allowSecret || task.claimedBy != environment.actor.description
      let approval = try approval(required: required, command: command + " -F <file>")
      guard TaskEditDocument(task) == original, task.planRev == before.planRev else {
        throw TaskError.edited(task.ref)
      }
      guard content != original else { return (receipt(task), false) }
      try applyEdit(content, task: task, redacted: redacted, at: at, in: tx)
      try approval?.record(
        command: command, workspace: slug,
        identity: (environment.ids, at), in: tx)
      return (receipt(task, warnings: redacted ? [SecretGuard.warning] : []), required)
    }
  }

  private func safeDocument(_ values: [String], from task: TaskDetails) -> TaskEditDocument {
    var document = TaskEditDocument(task)
    document.title = values[0]
    document.description = values[1]
    document.acceptance = values[2]
    document.plan = values[3]
    document.result = values[4]
    return document
  }

  private func applyEdit(
    _ document: TaskEditDocument, task: TaskDetails, redacted: Bool,
    at date: Date, in tx: StorageTransaction
  ) throws {
    if document.plan != task.plan {
      try writePlan(document.plan, task: task, redacted: false, at: date, in: tx)
    }
    try tx.database.execute(
      sql: """
        UPDATE task
        SET title=?,description_md=?,acceptance_md=?,result_md=?,updated_at=?,
          claimed_at=CASE WHEN claimed_by=? THEN ? ELSE claimed_at END
        WHERE id=?
        """,
      arguments: [
        document.title, document.description, document.acceptance,
        document.result == (task.result ?? "") ? task.result : document.result,
        Self.timestamp(date), environment.actor.description, Self.timestamp(date), task.id,
      ])
    try changed(task.id, kind: "field", body: "edited", redacted: redacted, at: date, in: tx)
  }
}
