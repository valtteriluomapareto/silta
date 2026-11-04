import Foundation
import GRDB

extension TaskService {
  /// Posts discussion atomically without taking another actor's claim. Own posts
  /// refresh the heartbeat; an own handoff releases it without changing status.
  package func comment(_ ref: String, _ input: CommentDraft) throws -> CommentResult {
    let slug = try selected()
    let command = Self.commentCommand(ref, input, workspace: slug)
    let consent = try approval(
      required: input.allowSecret, command: command + " --allow-secret -F <file>")
    let (draft, redacted) = try checkedComment(input, command: command)
    let at = environment.clock.now()
    return try environment.db.write { tx in
      let task = try Self.lookup(ref, workspace: slug, in: tx.database)
      try Self.mutable(task)
      let (id, seq) = try insertComment(draft, task: task, at: at, in: tx)
      try touchDiscussion(task, handoff: draft.kind == "handoff", at: at, in: tx)
      if redacted { try changed(task.id, kind: "secret_redacted", body: nil, at: at, in: tx) }
      try tx.recordChange(kind: "comment", rowID: id)
      try consent?.record(
        command: audited(Self.commentCommand(task.ref, draft))
          + (draft.allowSecret ? " --allow-secret" : "")
          + " -> \(task.ref)/\(seq)", workspace: slug, identity: (environment.ids, at), in: tx)
      guard
        let row = try Row.fetchOne(
          tx.database, sql: Self.commentQuery + " WHERE c.id=?", arguments: [id])
      else { throw StorageError.unavailable }
      var warnings = redacted ? [SecretGuard.warning] : []
      if draft.kind == "handoff", task.claimedBy == nil {
        warnings.append(
          OutputWarning(
            code: "handoff_unclaimed",
            message: "This task had no claim; the handoff records context only."))
      }
      return CommentResult(
        comment: CommentDetails(row: row, task: task.ref), warnings: warnings,
        approvalUsed: consent != nil)
    }
  }

  private func insertComment(
    _ draft: CommentDraft, task: TaskDetails, at: Date, in tx: StorageTransaction
  ) throws -> (Int64, Int) {
    if draft.kind == "handoff", let holder = task.claimedBy,
      holder != environment.actor.description
    {
      throw CommentError.foreignHandoff(task.ref)
    }
    let seq =
      try Int.fetchOne(
        tx.database, sql: "SELECT coalesce(max(seq),0)+1 FROM comment WHERE task_id=?",
        arguments: [task.id]) ?? 1
    try tx.database.execute(
      sql: """
        INSERT INTO comment(uid,task_id,seq,kind,body_md,actor,created_at)
        VALUES(?,?,?,?,?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: at), task.id, seq, draft.kind,
        draft.body, environment.actor.description,
        Self.timestamp(at),
      ])
    let id = tx.database.lastInsertedRowID
    return (id, seq)
  }

  private func checkedComment(_ input: CommentDraft, command: String) throws -> (CommentDraft, Bool)
  {
    guard ["comment", "decision", "handoff"].contains(input.kind) else {
      throw CommentError.invalid("Use comment, decision or handoff.")
    }
    try Self.validateCommentBody(input.body)
    let body = try checked(input.body, allow: input.allowSecret, command: command + " -F <file>")
    try Self.validateCommentBody(body.0)
    var draft = input
    draft.body = body.0
    return (draft, body.1)
  }

  /// A body-free command omitting defaults; a supplied workspace scopes recovery.
  package static func commentCommand(
    _ ref: String, _ draft: CommentDraft, workspace: String? = nil
  ) -> String {
    let scope = workspace.map { "--ws " + shellWord($0) + " " } ?? ""
    return "silta " + scope + "comment " + shellWord(SecretGuard.redacted(ref))
      + (draft.kind == "comment" ? "" : " --kind " + shellWord(SecretGuard.redacted(draft.kind)))
  }

  private static func validateCommentBody(_ body: String) throws {
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      body.unicodeScalars.count <= 8000
    else {
      throw CommentError.invalid(
        "A comment needs a nonblank body of at most 8000 Unicode scalars; "
          + "summarize longer output and cite its file outside the repo."
      )
    }
  }

  private func touchDiscussion(
    _ task: TaskDetails, handoff: Bool, at: Date, in tx: StorageTransaction
  ) throws {
    guard task.claimedBy == environment.actor.description else { return }
    try tx.database.execute(
      sql: "UPDATE task SET claimed_by=?,claimed_at=?,updated_at=? WHERE id=?",
      arguments: [
        handoff ? nil : task.claimedBy, handoff ? nil : Self.timestamp(at), Self.timestamp(at),
        task.id,
      ])
    if handoff { try changed(task.id, kind: "claim", body: nil, at: at, in: tx) }
  }

}
