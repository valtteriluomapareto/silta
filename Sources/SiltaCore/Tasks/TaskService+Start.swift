package import Foundation
import GRDB

extension TaskService {
  /// Claims open work atomically, refusing another session's fresh claim.
  /// `--steal` is human-only only when it overrides such a claim, decided again inside the
  /// write; otherwise it changes nothing. It never reopens a proposal or a terminal task.
  package func start(_ ref: String, steal: Bool = false, directory: URL) async throws
    -> (result: TaskResult, approvalUsed: Bool)
  {
    let command = "silta task start " + shellWord(ref) + " --steal"
    let before = try show(ref)
    let at = environment.clock.now()
    try validateClaim(before, at: at, steal: steal)
    try canStart(before)
    _ = try approval(required: steal && foreignClaim(before, at: at) != nil, command: command)
    let git = try await TaskGit.inspect(
      repo: before.repoPath, directory: directory, runner: environment.git,
      enabled: before.appID != nil, completion: false)
    let slug = try selected()
    return try environment.db.write { tx in
      let task = try Self.decorate(
        Self.lookup(ref, workspace: slug, in: tx.database),
        at: at, in: tx.database)
      try validateClaim(task, at: at, steal: steal)
      try canStart(task)
      let approval = try approval(
        required: steal && foreignClaim(task, at: at) != nil, command: command)
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
      return (receipt(try Self.lookup(ref, workspace: slug, in: tx.database)), approval != nil)
    }
  }

  private func canStart(_ task: TaskDetails) throws {
    if task.status == "blocked", let waiting = task.waiting {
      throw TaskError.blocked(task.ref, waiting)
    }
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
  package func submit(_ ref: String) throws -> TaskResult {
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
      try changed(task.id, kind: "status", body: "review", at: at, in: tx)
      return receipt(try Self.lookup(ref, workspace: slug, in: tx.database))
    }
  }
}
