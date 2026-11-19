import Foundation
import GRDB

extension TaskService {
  /// Validates the entire batch before approval and body input, then rechecks it
  /// before applying the decisions and recording their single approval.
  package func triage(_ batch: TaskTriage, readBody: (() throws -> String?)? = nil)
    throws -> [TaskResult]
  {
    guard !batch.accept.isEmpty || !batch.drop.isEmpty else {
      throw TaskError.invalid("Triage needs at least one --accept or --drop reference.")
    }
    if let priority = batch.priority { try Self.validatePriority(priority) }
    let slug = try selected()
    let preflightAt = environment.clock.now()
    let (beforeAccept, beforeDrop) = try environment.db.read {
      try triageTasks(batch, workspace: slug, at: preflightAt, in: $0)
    }
    let command = batch.command
    let flag = retryBodyFlag ?? (batch.why == nil ? nil : "-F -")
    let retry = scopedCommand(command, workspace: slug) + (flag.map { " " + $0 } ?? "")
    let approval = try approval(required: true, command: retry)
    let why = try readBody?() ?? batch.why
    let content = try checked(
      why ?? "Dropped in triage.", allow: batch.allowSecret, command: retry)
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let (accepted, dropped) = try triageTasks(batch, workspace: slug, at: at, in: tx.database)
      try verifyTriageIdentity(beforeAccept + beforeDrop, accepted + dropped)
      for task in accepted + dropped {
        let accept = accepted.contains { $0.id == task.id }
        try tx.database.execute(
          sql: """
            UPDATE task
            SET status=?,priority=?,result_md=?,closed_at=?,claimed_by=NULL,claimed_at=NULL,
              updated_at=?
            WHERE id=?
            """,
          arguments: [
            accept ? "todo" : "dropped",
            batch.priority.map { accept ? $0 : task.priority } ?? task.priority,
            accept ? task.result : content.0, accept ? nil : Self.timestamp(at),
            Self.timestamp(at), task.id,
          ])
        try changed(
          task.id, kind: "status", body: accept ? "todo" : "dropped",
          redacted: !accept && content.1, at: at, in: tx)
      }
      try approval?.record(
        command: audited(command), workspace: slug,
        identity: (environment.ids, at), in: tx)
      return accepted.map { TaskResult(ref: $0.ref, status: "todo", warnings: []) }
        + dropped.map {
          TaskResult(
            ref: $0.ref, status: "dropped", warnings: content.1 ? [SecretGuard.warning] : [])
        }
    }
  }

  private func verifyTriageIdentity(_ before: [TaskDetails], _ after: [TaskDetails]) throws {
    for (original, current) in zip(before, after) where original.uid != current.uid {
      throw TaskError.triageChanged(original.ref)
    }
  }

  private func triageTasks(_ batch: TaskTriage, workspace: String, at date: Date, in db: Database)
    throws -> (accepted: [TaskDetails], dropped: [TaskDetails])
  {
    let accepted = try triageTasks(batch.accept, workspace: workspace, at: date, in: db)
    let dropped = try triageTasks(batch.drop, workspace: workspace, at: date, in: db)
    if let overlap = accepted.first(where: { task in dropped.contains { $0.id == task.id } }) {
      throw TaskError.invalid("\(overlap.ref) cannot be both accepted and dropped.")
    }
    return (accepted, dropped)
  }

  private func triageTasks(_ refs: [String], workspace: String, at date: Date, in db: Database)
    throws -> [TaskDetails]
  {
    var tasks: [TaskDetails] = []
    for ref in refs {
      let task: TaskDetails
      do { task = try Self.lookup(ref, workspace: workspace, in: db) } catch TaskError.notFound {
        throw TaskReferenceError(ref: ref, missing: true)
      } catch TaskError.invalid { throw TaskReferenceError(ref: ref, missing: false) }
      try validateClaim(task, workspace: workspace, at: date)
      guard task.status == "proposed" else {
        throw TaskError.transition(task.ref, status: task.status)
      }
      if !tasks.contains(where: { $0.id == task.id }) { tasks.append(task) }
    }
    return tasks
  }
}

/// Preserves the failure category while naming a bad reference in a batch.
package struct TaskReferenceError: CodedError {
  let ref: String

  let missing: Bool

  /// Names the batch reference and its failure category.
  package init(ref: String, missing: Bool) {
    self.ref = SecretGuard.redacted(ref).unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) ? " " : String($0)
    }.joined()
    self.missing = missing
  }

  /// Preserves not-found versus invalid reference failures.
  package var code: ErrorCode {
    missing ? .notFound : .invalid
  }

  /// Identifies the failing batch member.
  package var message: String {
    "\(ref): \(missing ? "task not found" : "invalid task reference")."
  }

  /// Points to the selected workspace backlog.
  package var next: [String] {
    ["silta task ls"]
  }
}
