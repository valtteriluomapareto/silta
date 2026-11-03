import SiltaCore

/// Shapes and text shared by the task commands that return the same persisted values.
enum TaskOutput {
  static let receiptShape = Shape.object(["ref": .string, "status": .string])

  static let detailShape = Shape.object([
    "ref": .string, "title": .string, "status": .string, "description": .string,
    "acceptance": .string, "priority": .int, "archived": .bool,
    "archive_override": .optional(.string), "external_ref": .optional(.string),
    "plan": .string, "plan_rev": .int, "result": .optional(.string), "created_by": .string,
    "claimed_by": .optional(.string), "claimed_at": .optional(.string), "app": .optional(.string),
    "branch": .optional(.string), "worktree": .optional(.string), "done_sha": .optional(.string),
    "done_branch": .optional(.string), "done_dirty": .optional(.bool),
    "links": .array(.object(["rel": .string, "target": .string])),
    "timeline": .optional(
      .array(
        .object([
          "kind": .string, "actor": .string, "body": .optional(.string), "at": .string,
        ]))),
  ])

  static func receipt(_ result: TaskResult, approvalUsed: Bool = false) -> CommandOutput {
    CommandOutput(
      text: "\(result.ref) \(result.status)", data: result, warnings: result.warnings,
      approvalUsed: approvalUsed)
  }

  static func summary(_ task: TaskDetails) -> String {
    let tracker = task.externalRef.map { " [read-only: " + $0 + "]" } ?? ""
    return "\(task.ref) \(task.status) (priority \(task.priority)): \(task.title)" + tracker
  }

  static func detail(_ task: TaskDetails) -> String {
    var lines = [summary(task), "Created by: \(task.createdBy)"]
    lines.append("Archived: \(task.archived ? "yes" : "no")")
    if let claim = task.claimedBy { lines.append("Claimed by: \(claim)") }
    for (heading, text) in [
      ("Description", task.description),
      ("Acceptance", task.acceptance),
      ("Plan (revision \(task.planRev))", task.plan),
      ("Result", task.result ?? ""),
    ] where !text.isEmpty {
      lines.append("\n\(heading):\n\(text)")
    }
    if let sha = task.doneSHA { lines.append("Commit: \(sha)") }
    for link in task.links { lines.append("\(link.rel): \(link.target)") }
    for event in task.timeline ?? [] {
      lines.append("\(event.at) \(event.actor) \(event.kind): \(event.body ?? "")")
    }
    return lines.joined(separator: "\n")
  }
}
