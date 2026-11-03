import Foundation
import GRDB

extension TaskService {
  /// Replaces a plan with a new immutable revision, optionally comparing the revision read.
  package func plan(
    _ ref: String, text: String, ifRevision: Int? = nil, allowSecret: Bool = false
  ) throws -> TaskPlanResult {
    let content = try checked(
      text, allow: allowSecret, command: "silta task plan " + shellWord(ref) + " -F <file>")
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      try Self.compareRevision(ifRevision, task: task)
      try writePlan(content.0, task: task, redacted: content.1, at: at, in: tx)
      return TaskPlanResult(
        ref: task.ref, planRev: task.planRev + 1, plan: content.0,
        warnings: content.1 ? [SecretGuard.warning] : [])
    }
  }

  /// Changes just the selected top-level checkbox and keeps the revision snapshot intact.
  package func tick(_ ref: String, step: Int, done: Bool, ifRevision: Int? = nil) throws
    -> TaskPlanResult
  {
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      try Self.compareRevision(ifRevision, task: task)
      let text = try MarkdownPlan.tick(task.plan, step: step, done: done)
      try updatePlan(text, revision: task.planRev, task: task.id, at: at, in: tx.database)
      try changed(task.id, kind: "step", body: "\(step) \(done ? "done" : "undo")", at: at, in: tx)
      return TaskPlanResult(ref: task.ref, planRev: task.planRev, plan: text)
    }
  }

  static func compareRevision(_ expected: Int?, task: TaskDetails) throws {
    if let expected {
      guard expected >= 0 else { throw TaskError.invalid("--if-rev must be nonnegative.") }
      if expected != task.planRev { throw TaskError.staleRev(task.ref, actual: task.planRev) }
    }
  }

  func writePlan(
    _ text: String, task: TaskDetails, redacted: Bool, at date: Date, in tx: StorageTransaction
  ) throws {
    let rev = task.planRev + 1
    try updatePlan(text, revision: rev, task: task.id, at: date, in: tx.database)
    try tx.database.execute(
      sql: """
        INSERT INTO task_plan_rev(task_id,rev,body_md,actor,created_at)
        VALUES(?,?,?,?,?)
        """, arguments: [task.id, rev, text, environment.actor.description, Self.timestamp(date)])
    try changed(task.id, kind: "plan", body: "\(rev)", redacted: redacted, at: date, in: tx)
  }

  private func updatePlan(
    _ text: String, revision: Int, task: Int64, at date: Date, in db: Database
  ) throws {
    try db.execute(
      sql: """
        UPDATE task
        SET plan_md=?,plan_rev=?,updated_at=?,
          claimed_at=CASE WHEN claimed_by=? THEN ? ELSE claimed_at END
        WHERE id=?
        """,
      arguments: [
        text, revision, Self.timestamp(date), environment.actor.description,
        Self.timestamp(date), task,
      ])
  }
}
