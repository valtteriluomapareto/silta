package import Foundation
import GRDB

extension TaskService {
  /// Stores a result and closes work, releasing the claim in the same write.
  /// App completion records its commit outside the transaction, then rechecks the task.
  package func close(
    _ ref: String, result: String?, dropped: Bool = false,
    commit: TaskCommit = TaskCommit(), directory: URL
  ) async throws -> TaskResult {
    if commit.force {
      try environment.actor.requireHuman(
        command: "silta task done " + shellWord(ref) + " --force -F <file>")
    }
    let command = (dropped ? "silta task drop " : "silta task done ") + shellWord(ref)
    let content = try checked(result ?? "", allow: commit.allowSecret, command: command)
    try requireResult(content.0)
    guard !(commit.sha != nil && commit.noSHA) else {
      throw TaskError.invalid("--sha and --no-sha cannot be combined.")
    }
    let before = try show(ref)
    try canClose(before, dropped: dropped)
    let at = environment.clock.now()
    try validateClaim(before, at: at)
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
      try canClose(task, dropped: dropped)
      try validateClaim(task, at: at)
      try Self.sameRepository(task, before)
      var warnings = content.1 ? [SecretGuard.warning] : []
      if !dropped { warnings += try gate(task, force: commit.force, in: tx.database) }
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
      try changed(
        task.id, kind: "status", body: dropped ? "dropped" : "done",
        redacted: content.1, at: at, in: tx)
      return receipt(try Self.lookup(ref, workspace: slug, in: tx.database), warnings: warnings)
    }
  }

  private func requireResult(_ text: String) throws {
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
    guard ["todo", "doing", "review"].contains(task.status) else {
      throw TaskError.transition(task.ref, status: task.status)
    }
  }

  private func gate(_ task: TaskDetails, force: Bool, in db: Database) throws -> [OutputWarning] {
    guard !force else { return [] }
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
      if !approved { throw TaskError.gate(task.ref) }
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
        return [
          OutputWarning(code: "review_changes", message: "The latest review requests changes.")
        ]
      }
    }
    return []
  }
}
