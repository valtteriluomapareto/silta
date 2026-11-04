import Foundation
import GRDB

extension TaskService {
  /// Edits a snapshot, then rechecks content, promotion and the current claim before writing.
  /// A nil callback result cancels without writing. An edit that changes nothing writes
  /// nothing and uses no approval. Only changed fields pass the secret guard. The result's
  /// `changed` names the fields written.
  package func edit(
    _ ref: String, allowSecret: Bool = false, input: (String) throws -> String?
  ) throws -> (result: TaskResult, approvalUsed: Bool) {
    let command =
      "silta task edit " + shellWord(ref)
      + (allowSecret ? " --allow-secret" : "")
    let slug = try selected()
    let before = try show(ref)
    try validateClaim(before, workspace: slug, at: environment.clock.now())
    let needed = allowSecret || before.claimedBy != environment.actor.description
    _ = try approval(required: needed, command: command + " -F <file>")
    let original = TaskEditDocument(before)
    guard let text = try input(original.render()) else { return (receipt(before), false) }
    let parsed = try TaskEditDocument.parse(text, from: before)
    if parsed == original {
      return try unchangedEdit(before, allowSecret: allowSecret, command: command)
    }
    try keepsBodies(parsed, original)
    let safe = try zip(parsed.values, original.values).map { value, old in
      value.utf8.elementsEqual(old.utf8)
        ? (value, false) : try checked(value, allow: allowSecret, command: command + " -F <file>")
    }
    let content = safeDocument(safe.map(\.0), from: before)
    let redacted = safe.contains { $0.1 }
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, workspace: slug, at: at)
      let required = allowSecret || task.claimedBy != environment.actor.description
      let approval = try approval(required: required, command: command + " -F <file>")
      try Self.compareEdit(task, before)
      guard content != original else { return (receipt(task), false) }
      try applyEdit(content, task: task, redacted: redacted, at: at, in: tx)
      try approval?.record(
        command: audited(command), workspace: slug,
        identity: (environment.ids, at), in: tx)
      var result = receipt(task, warnings: redacted ? [SecretGuard.warning] : [])
      result.changed = content.changed(from: original)
      return (result, required)
    }
  }

  private func unchangedEdit(_ before: TaskDetails, allowSecret: Bool, command: String) throws
    -> (result: TaskResult, approvalUsed: Bool)
  {
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.read { db in
      let task = try Self.lookup(before.ref, workspace: slug, in: db)
      try validateClaim(task, workspace: slug, at: at)
      let required = allowSecret || task.claimedBy != environment.actor.description
      _ = try approval(required: required, command: command + " -F <file>")
      try Self.compareEdit(task, before)
      return (receipt(task), false)
    }
  }

  /// The current edit document, exactly as `-F` takes it back. A read: no approval.
  package func editDocument(_ ref: String) throws -> (task: TaskDetails, document: String) {
    let task = try show(ref)
    return (task, TaskEditDocument(task).render())
  }

  /// An agent can't clear a stored Result or Plan, so a document written from a partial
  /// read can't wipe them; a human may.
  private func keepsBodies(_ parsed: TaskEditDocument, _ original: TaskEditDocument) throws {
    guard !environment.actor.isHuman else { return }
    for (name, value, old) in [
      ("Result", parsed.result, original.result), ("Plan", parsed.plan, original.plan),
    ] where Self.blank(value) && !Self.blank(old) {
      throw TaskError.invalid(
        "An agent edit cannot clear the \(name); keep its text, or ask a human to clear it.")
    }
  }

  private static func blank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func compareEdit(_ task: TaskDetails, _ before: TaskDetails) throws {
    guard TaskEditDocument(task) == TaskEditDocument(before), task.planRev == before.planRev else {
      throw TaskError.edited(task.ref)
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
    if !document.plan.utf8.elementsEqual(task.plan.utf8) {
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
        document.result.utf8.elementsEqual((task.result ?? "").utf8)
          ? task.result : document.result,
        Self.timestamp(date), environment.actor.description, Self.timestamp(date), task.id,
      ])
    try changed(task.id, kind: "field", body: "edited", redacted: redacted, at: date, in: tx)
  }
}
