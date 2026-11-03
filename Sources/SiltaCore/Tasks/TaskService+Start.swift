package import Foundation
import GRDB

extension TaskService {
  /// Claims open work atomically, refusing another session's fresh claim.
  /// Human-only steal never reopens a proposal or a terminal task.
  package func start(_ ref: String, steal: Bool = false, directory: URL) async throws -> TaskResult
  {
    let command = "silta task start " + shellWord(ref) + " --steal"
    let approval = try approval(required: steal, command: command)
    let before = try show(ref)
    try canStart(before)
    let at = environment.clock.now()
    try validateClaim(before, at: at, steal: steal)
    let git = try await TaskGit.inspect(
      repo: before.repoPath, directory: directory, runner: environment.git,
      enabled: before.appID != nil, completion: false)
    let slug = try selected()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try canStart(task)
      try validateClaim(task, at: at, steal: steal)
      try Self.sameRepository(task, before)
      try tx.database.execute(
        sql: """
          UPDATE task
          SET status='doing',claimed_by=?,claimed_at=?,branch=?,worktree=?,updated_at=?
          WHERE id=?
          """,
        arguments: [
          environment.actor.description, Self.timestamp(at), git.branch,
          git.worktree, Self.timestamp(at), task.id,
        ])
      try changed(task.id, kind: "claim", body: nil, at: at, in: tx)
      try approval?.record(
        command: command, workspace: slug, identity: (environment.ids, at), in: tx)
      return receipt(try Self.lookup(ref, workspace: slug, in: tx.database))
    }
  }

  private func canStart(_ task: TaskDetails) throws {
    if task.status == "proposed" { throw TaskError.proposal(task.ref) }
    guard ["todo", "doing", "review"].contains(task.status) else {
      throw TaskError.transition(task.ref, status: task.status)
    }
  }

  static func sameRepository(_ task: TaskDetails, _ before: TaskDetails) throws {
    guard task.appID == before.appID, task.repoPath == before.repoPath,
      task.worktree == before.worktree
    else { throw TaskError.changed(task.ref) }
  }

  /// Submits doing work for review while refreshing its owner's heartbeat.
  package func submit(_ ref: String, body: String? = nil, allowSecret: Bool = false) throws
    -> TaskResult
  {
    let command = "silta task submit " + shellWord(ref)
    let approval = try approval(
      required: allowSecret, command: command + " -F <file> --allow-secret")
    let content = try checked(body ?? "", allow: allowSecret, command: command + " -F <file>")
    let slug = try selected()
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try validateClaim(task, at: at)
      guard task.status == "doing" else {
        throw TaskError.transition(task.ref, status: task.status)
      }
      try tx.database.execute(
        sql: """
          UPDATE task
          SET status='review',updated_at=?,
            claimed_at=CASE WHEN claimed_by=? THEN ? ELSE claimed_at END
          WHERE id=?
          """,
        arguments: [Self.timestamp(at), environment.actor.description, Self.timestamp(at), task.id])
      try changed(task.id, kind: "status", body: content.0, redacted: content.1, at: at, in: tx)
      try approval?.record(
        command: command + " --allow-secret", workspace: slug,
        identity: (environment.ids, at), in: tx)
      return receipt(
        try Self.lookup(ref, workspace: slug, in: tx.database),
        warnings: content.1 ? [SecretGuard.warning] : [])
    }
  }
}
