package import Foundation
import GRDB

extension TaskService {
  /// The recorded worktree, or the caller's directory once that worktree is removed (the
  /// merger finishing after review); `TaskGit.inspect` still refuses another repository.
  static func completionDirectory(_ task: TaskDetails, fallback: URL) -> URL {
    guard let path = task.worktree, FileManager.default.fileExists(atPath: path) else {
      return fallback
    }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

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
    let slug = try selected()
    try validateClaim(before, workspace: slug, at: at)
    try closable(before, dropped: dropped, commit: commit, audit: audit)
    let git = try await TaskGit.inspect(
      repo: before.repoPath, directory: Self.completionDirectory(before, fallback: directory),
      runner: environment.git,
      enabled: !dropped && !commit.noSHA && before.appID != nil, completion: true, sha: commit.sha)
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, workspace: slug, at: at)
      try canClose(task, dropped: dropped)
      try Self.sameRepository(task, before)
      let review = try review(
        task, dropped: dropped, commit: commit, command: audit, in: tx.database)
      var warnings = (content.1 ? [SecretGuard.warning] : []) + review.warnings
      let used = approval ?? review.forced
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
      try used?.record(
        command: audited(audit), workspace: slug, identity: (environment.ids, at), in: tx)
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
      if !dropped { throw TaskError.proposal(task.ref, human: environment.actor.isHuman) }
      if !environment.actor.isHuman && task.createdBy != environment.actor.description {
        throw TaskError.proposal(task.ref, human: false)
      }
      return
    }
    guard ["todo", "doing", "review", "blocked"].contains(task.status) else {
      throw TaskError.transition(task.ref, status: task.status)
    }
  }

  /// Everything a close checks before git runs, so a refusal never waits on git.
  private func closable(
    _ task: TaskDetails, dropped: Bool, commit: TaskCommit, audit: String
  ) throws {
    try canClose(task, dropped: dropped)
    if commit.sha != nil, task.appID == nil || dropped {
      throw TaskError.invalid("--sha requires an app task completed with done.")
    }
    _ = try environment.db.read {
      try review(task, dropped: dropped, commit: commit, command: audit, in: $0)
    }
  }

  /// The review gate's warnings for a completion. An unmet gate refuses it unless
  /// `--force` has the human's go-ahead, which is then the approval this write records.
  private func review(
    _ task: TaskDetails, dropped: Bool, commit: TaskCommit, command: String, in db: Database
  ) throws -> (warnings: [OutputWarning], forced: HumanApproval?) {
    guard !dropped else { return ([], nil) }
    let review = try gate(task, in: db)
    guard review.unmet else { return (review.warnings, nil) }
    guard commit.force else { throw TaskError.gate(task.ref) }
    return (review.warnings, try approval(required: true, command: command + " -F <file>"))
  }

  /// The review gate's warnings, and whether an unmet `human` gate refuses completion.
  private func gate(_ task: TaskDetails, in db: Database) throws
    -> (warnings: [OutputWarning], unmet: Bool)
  {
    let gate = try WorkspaceSettings.read(workspaceID: task.workspaceID, in: db).reviewGate
    if gate == .human {
      let approved =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(SELECT 1 FROM comment
              WHERE task_id=? AND verdict='approve' AND actor LIKE 'human:%' AND deleted_at IS NULL)
            """, arguments: [task.id]) ?? false
      return ([], !approved)
    }
    if gate == .any {
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
