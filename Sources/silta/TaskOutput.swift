import SiltaCore

/// Shapes and text shared by the task commands that return the same persisted values.
enum TaskOutput {
  static let receiptShape = Shape.object(["ref": .string, "status": .string])

  static let waitingShape = Shape.object([
    "on": .array(.string), "age_days": .int, "why": .string, "ready": .bool,
    "dropped": .array(.string),
  ])

  /// What `task ls` returns per task (spec §16): enough to choose work, no bodies.
  static let summaryShape = Shape.object([
    "ref": .string, "title": .string, "status": .string, "priority": .int,
    "app": .optional(.string), "parent": .optional(.string),
    "claimed_by": .optional(.string), "claimed_at": .optional(.string),
    "external_ref": .optional(.string), "waiting": .optional(waitingShape),
    "follow_up_at": .optional(.string), "created_by": .string, "created_at": .string,
    "updated_at": .string, "archived": .bool, "links": linksShape,
  ])

  static let linksShape = Shape.array(.object(["rel": .string, "target": .string]))

  static let detailShape = Shape.object([
    "ref": .string, "title": .string, "status": .string, "description": .string,
    "follow_up_at": .optional(.string), "waiting": .optional(waitingShape),
    "acceptance": .string, "priority": .int, "archived": .bool,
    "archive_override": .optional(.string), "external_ref": .optional(.string),
    "plan": .string, "plan_rev": .int, "result": .optional(.string), "created_by": .string,
    "created_at": .string, "updated_at": .string, "parent": .optional(.string),
    "claimed_by": .optional(.string), "claimed_at": .optional(.string), "app": .optional(.string),
    "branch": .optional(.string), "worktree": .optional(.string), "done_sha": .optional(.string),
    "done_branch": .optional(.string), "done_dirty": .optional(.bool),
    "links": linksShape,
    "comments": .optional(.array(CommentOutput.shape)),
    "handed_off": .optional(.string), "resolved_threads": .optional(.int),
    "timeline": .optional(
      .array(
        .object([
          "kind": .string, "actor": .string, "body": .optional(.string), "at": .string,
        ]))),
  ])

  /// A receipt's text: what changed (`AC-5 archived`) or the status, then an inherited app.
  static func receiptText(_ result: TaskResult, change: String? = nil) -> String {
    "\(result.ref) \(change ?? result.status)"
      + (result.inheritedApp.map { " (app \($0))" } ?? "")
  }

  /// A receipt whose text says what changed (`AC-5 archived`), or the status by default.
  /// `quiet` is what `--quiet` keeps: the ref a write created.
  static func receipt(
    _ result: TaskResult, change: String? = nil, quiet: String = "", approvalUsed: Bool = false
  ) -> CommandOutput {
    CommandOutput(
      text: receiptText(result, change: change), quiet: quiet, data: result,
      warnings: result.warnings, approvalUsed: approvalUsed)
  }

  static func summary(_ task: TaskDetails) -> String {
    let tracker = task.externalRef.map { " [read-only: " + $0 + "]" } ?? ""
    let parent = task.parent.map { ", parent " + $0 } ?? ""
    return "\(task.ref) \(task.status) (priority \(task.priority)\(parent)): \(task.title)"
      + tracker
      + (task.waiting.map { "\n" + waitingLines($0).joined(separator: "\n") } ?? "")
  }

  static func waitingLines(_ waiting: TaskWaiting) -> [String] {
    var lines = [
      "Waiting on \(waiting.on.isEmpty ? "an answer" : waiting.on.joined(separator: ", ")) for \(waiting.ageDays) d: \(waiting.why)"
    ]
    if waiting.ready { lines.append("Ready to unblock.") }
    if !waiting.dropped.isEmpty {
      lines.append("Blocker dropped: re-plan (" + waiting.dropped.joined(separator: ", ") + ")")
    }
    return lines
  }

  static func detail(_ task: TaskDetails, workspace: String) -> String {
    var lines = [summary(task), "Created by: \(task.createdBy)"]
    if let app = task.app { lines.append("App: \(app)") }
    lines.append("Archived: \(task.archived ? "yes" : "no")")
    if let day = task.followUpAt { lines.append("Follow-up: " + day) }
    if let claim = task.claimedBy { lines.append("Claimed by: \(claim)") }
    if task.resumeAvailable {
      let context = task.handedOff.map { " (handed off " + $0 + ")" } ?? ""
      lines.append(
        "Unclaimed" + context + "; next: silta --ws "
          + shellWord(workspace) + " task start " + shellWord(task.ref))
    }
    for (heading, text) in [
      ("Description", task.description),
      ("Acceptance", task.acceptance),
      ("Plan (revision \(task.planRev))", MarkdownPlan.numbered(task.plan)),
      ("Result", task.result ?? ""),
    ] where !text.isEmpty {
      lines.append("\n\(heading):\n\(text)")
    }
    if let sha = task.doneSHA { lines.append("Commit: \(sha)") }
    for link in task.links { lines.append("\(link.rel): \(link.target)") }
    if let comments = task.comments {
      lines.append("\nDiscussion:")
      lines += comments.map {
        CommentOutput.detail(
          $0, comments: comments, timeline: task.timeline != nil)
      }
    }
    if let count = task.resolvedThreads {
      lines.append("\n\(count) resolved thread\(count == 1 ? "" : "s") (see --timeline)")
    }
    for event in task.timeline ?? [] {
      lines.append(
        "\(event.at) \(event.actor) \(event.kind)" + (event.body.map { ": " + $0 } ?? ""))
    }
    return lines.joined(separator: "\n")
  }
}
