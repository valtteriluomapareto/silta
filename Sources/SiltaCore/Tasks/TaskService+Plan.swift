import Foundation
import GRDB

extension TaskService {
  /// Replaces a plan with a new immutable revision, optionally comparing the revision read.
  package func plan(
    _ ref: String, text: String, ifRevision: Int? = nil, allowSecret: Bool = false
  ) throws -> TaskPlanResult {
    let command = Self.planCommand(ref, ifRevision: ifRevision)
    let approval = try approval(
      required: allowSecret, command: command + " -F <file> --allow-secret")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskError.invalid("A plan revision needs a nonblank body from -m or -F <file>.")
    }
    let content = try checked(
      text, allow: allowSecret,
      command: Self.planCommand(ref, ifRevision: ifRevision) + " -F <file>")
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      try Self.compareRevision(ifRevision, task: task)
      try writePlan(content.0, task: task, redacted: content.1, at: at, in: tx)
      try approval?.record(
        command: command + " --allow-secret", workspace: slug,
        identity: (environment.ids, at), in: tx)
      return TaskPlanResult(
        ref: task.ref, planRev: task.planRev + 1, plan: content.0,
        warnings: content.1 ? [SecretGuard.warning] : [])
    }
  }

  /// Ticks a top-level checkbox without creating a revision. A tick adds no text, so the
  /// secret guard has nothing new to check and the rest of the plan stays as stored.
  package func tick(_ ref: String, step: Int, done: Bool, ifRevision: Int? = nil) throws
    -> TaskPlanResult
  {
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      try Self.compareRevision(ifRevision, task: task)
      guard !MarkdownPlan.checkboxes(task.plan).isEmpty else {
        throw TaskError.noCheckboxes(task.ref)
      }
      let text = try MarkdownPlan.tick(task.plan, step: step, done: done)
      try updatePlan(text, revision: task.planRev, task: task.id, at: at, in: tx.database)
      try changed(
        task.id, kind: "step", body: "\(step) \(done ? "done" : "undo")", at: at, in: tx)
      var result = TaskPlanResult(ref: task.ref, planRev: task.planRev, plan: text)
      result.step = step
      result.done = done
      result.title = MarkdownPlan.checkboxes(text)[step - 1].title
      return result
    }
  }

  /// A body-free replacement command retains the revision guard in both CLI and core retries.
  package static func planCommand(_ ref: String, ifRevision: Int?) -> String {
    "silta task plan " + shellWord(ref)
      + (ifRevision.map { " --if-rev \($0)" } ?? "")
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
