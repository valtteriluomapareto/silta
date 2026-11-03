package import Foundation
import GRDB

extension TaskService {
  /// Stores a result and closes work, releasing the claim in the same write.
  /// App completion records its commit outside the transaction, then rechecks the task.
  /// `--force` is human-only only when it overrides an unmet review gate, decided again
  /// inside the write; otherwise it changes nothing.
  package func close(
    _ ref: String, result: String?, dropped: Bool = false,
    commit: TaskCommit = TaskCommit(), directory: URL
  ) async throws -> (result: TaskResult, approvalUsed: Bool) {
    let command = commit.command(ref, dropped: dropped)
    let audit = command + (commit.allowSecret ? " --allow-secret" : "")
    let approval = try approval(required: commit.allowSecret, command: audit + " -F <file>")
    let content = try checked(
      result ?? "", allow: commit.allowSecret, command: command + " -F <file>")
    try validateResult(content.0, commit: commit)
    let before = try show(ref)
    let at = environment.clock.now()
    try validateClaim(before, at: at)
    try canClose(before, dropped: dropped)
    if commit.force, !dropped, try environment.db.read({ try gate(before, in: $0).unmet }) {
      _ = try self.approval(required: true, command: audit + " -F <file>")
    }
    if commit.sha != nil, before.appID == nil || dropped {
      throw TaskError.invalid("--sha requires an app task completed with done.")
    }
    let cwd = before.worktree.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? directory
    let git = try await TaskGit.inspect(
      repo: before.repoPath, directory: cwd, runner: environment.git,
      enabled: !dropped && !commit.noSHA && before.appID != nil, completion: true, sha: commit.sha)
    let slug = try selected()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      try canClose(task, dropped: dropped)
      try Self.sameRepository(task, before)
      var warnings = content.1 ? [SecretGuard.warning] : []
      var used = approval
      if !dropped {
        let review = try gate(task, in: tx.database)
        if review.unmet {
          guard commit.force else { throw TaskError.gate(task.ref) }
          used = try used ?? self.approval(required: true, command: audit + " -F <file>")
        }
        warnings += review.warnings
      }
      if git.dirty == true {
        warnings.append(
          OutputWarning(code: "dirty_worktree", message: "The task worktree is dirty."))
      }
      try tx.database.execute(
        sql: """
          UPDATE task
          SET status=?,result_md=?,done_sha=?,done_branch=?,done_dirty=?,
            claimed_by=NULL,claimed_at=NULL,closed_at=?,updated_at=?
          WHERE id=?
          """,
        arguments: [
          dropped ? "dropped" : "done", result == nil ? nil : content.0,
          git.sha, git.branch, git.dirty, Self.timestamp(at), Self.timestamp(at), task.id,
        ])
      try Self.clearBlock(task, in: tx)
      try changed(
        task.id, kind: "status", body: dropped ? "dropped" : "done",
        redacted: content.1, at: at, in: tx)
      try used?.record(command: audit, workspace: slug, identity: (environment.ids, at), in: tx)
      return (
        receipt(try Self.lookup(ref, workspace: slug, in: tx.database), warnings: warnings),
        used != nil
      )
    }
  }

  private func validateResult(_ text: String, commit: TaskCommit) throws {
    guard !(commit.sha != nil && commit.noSHA) else {
      throw TaskError.invalid("--sha and --no-sha cannot be combined.")
    }
    if !environment.actor.isHuman, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw TaskError.invalid("Agents must provide a nonblank result with -m or -F <file>.")
    }
  }

  private func canClose(_ task: TaskDetails, dropped: Bool) throws {
    if task.status == "proposed" {
      if !dropped { throw TaskError.proposal(task.ref) }
      if !environment.actor.isHuman && task.createdBy != environment.actor.description {
        throw TaskError.proposal(task.ref)
      }
      return
    }
    guard ["todo", "doing", "review", "blocked"].contains(task.status) else {
      throw TaskError.transition(task.ref, status: task.status)
    }
  }

  /// The review gate's warnings, and whether an unmet `human` gate refuses completion.
  private func gate(_ task: TaskDetails, in db: Database) throws
    -> (warnings: [OutputWarning], unmet: Bool)
  {
    let raw =
      try String.fetchOne(
        db, sql: "SELECT settings FROM workspace WHERE id=?",
        arguments: [task.workspaceID]) ?? "{}"
    let settings = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    let gate = settings?["review_gate"] as? String ?? "none"
    if gate == "human" {
      let approved =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(SELECT 1 FROM comment
              WHERE task_id=? AND verdict='approve' AND actor LIKE 'human:%' AND deleted_at IS NULL)
            """, arguments: [task.id]) ?? false
      return ([], !approved)
    }
    if gate == "any" {
      let latest = try String.fetchOne(
        db,
        sql: """
          SELECT verdict
          FROM comment
          WHERE task_id=? AND verdict IS NOT NULL AND deleted_at IS NULL
          ORDER BY id DESC
          LIMIT 1
          """, arguments: [task.id])
      if latest == "changes" {
        return (
          [OutputWarning(code: "review_changes", message: "The latest review requests changes.")],
          false
        )
      }
    }
    return ([], false)
  }
}
