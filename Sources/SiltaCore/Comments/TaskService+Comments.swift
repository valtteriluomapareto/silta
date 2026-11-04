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
      try commentCitation(draft.source, id: id, task: task, at: at, in: tx)
      try touchDiscussion(task, handoff: draft.kind == "handoff", at: at, in: tx)
      if redacted { try changed(task.id, kind: "secret_redacted", body: nil, at: at, in: tx) }
      try tx.recordChange(kind: "comment", rowID: id)
      try consent?.record(
        command: audited(command) + (draft.allowSecret ? " --allow-secret" : "")
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
        comment: try CommentDetails(row: row, task: task.ref), warnings: warnings,
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
    let root = try Self.replyRoot(draft, task: task, in: tx.database)
    let seq =
      try Int.fetchOne(
        tx.database, sql: "SELECT coalesce(max(seq),0)+1 FROM comment WHERE task_id=?",
        arguments: [task.id]) ?? 1
    try tx.database.execute(
      sql: """
        INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,mentions,actor,created_at)
        VALUES(?,?,?,?,?,?,?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: at), task.id, seq, root, draft.kind,
        draft.body, try OutputRouter.json(draft.to), environment.actor.description,
        Self.timestamp(at),
      ])
    let id = tx.database.lastInsertedRowID
    return (id, seq)
  }

  private func checkedComment(_ input: CommentDraft, command: String) throws -> (CommentDraft, Bool)
  {
    guard ["comment", "question", "answer", "decision", "handoff"].contains(input.kind) else {
      throw CommentError.invalid("Use comment, question, answer, decision or handoff.")
    }
    try Self.validateCommentBody(input.body)
    let body = try checked(input.body, allow: input.allowSecret, command: command + " -F <file>")
    try Self.validateCommentBody(body.0)
    let source = try input.source.map {
      try checked($0, allow: input.allowSecret, command: command)
    }
    if let source, !source.0.hasPrefix("note:") || source.0.count == 5 {
      throw CommentError.invalid("--from requires a note: reference.")
    }
    let to = try input.to.map { try checked($0, allow: input.allowSecret, command: command) }
    var draft = input
    draft.body = body.0
    draft.source = source?.0
    draft.to = try CommentMentions.parse(
      body.0, to: to.map(\.0), human: environment.human, question: input.kind == "question")
    return (draft, body.1 || source?.1 == true || to.contains { $0.1 })
  }

  /// A body-free retry retains all posting options and its selected workspace.
  package static func commentCommand(_ ref: String, _ draft: CommentDraft, workspace: String)
    -> String
  {
    var command =
      "silta --ws " + shellWord(workspace) + " comment " + shellWord(SecretGuard.redacted(ref))
      + " --kind " + shellWord(SecretGuard.redacted(draft.kind))
    if let reply = draft.replyTo {
      command += " --reply-to " + shellWord(SecretGuard.redacted(reply))
    }
    for actor in draft.to { command += " --to " + shellWord(SecretGuard.redacted(actor)) }
    if let source = draft.source { command += " --from " + shellWord(SecretGuard.redacted(source)) }
    return command
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

  private static func replyRoot(_ draft: CommentDraft, task: TaskDetails, in db: Database) throws
    -> Int64?
  {
    guard let ref = draft.replyTo else {
      if draft.kind == "answer" {
        throw CommentError.invalid("An answer needs --reply-to a question.")
      }
      return nil
    }
    guard draft.kind != "question" else {
      throw CommentError.invalid("Post questions as new threads, without --reply-to.")
    }
    let raw = ref.hasPrefix("task:") ? String(ref.dropFirst(5)) : ref
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == task.ref, let seq = Int(parts[1]), seq > 0,
      parts[1] == String(seq)
    else {
      throw CommentError.invalid("--reply-to needs a canonical comment reference in this task.")
    }
    guard
      let reply = try Row.fetchOne(
        db, sql: "SELECT * FROM comment WHERE task_id=? AND seq=? AND deleted_at IS NULL",
        arguments: [task.id, seq])
    else {
      throw CommentError.missing(SecretGuard.redacted(ref))
    }
    let rootID = (reply["thread_id"] as Int64?) ?? (reply["id"] as Int64)
    guard
      let root = try Row.fetchOne(
        db, sql: "SELECT * FROM comment WHERE id=? AND task_id=? AND thread_id IS NULL",
        arguments: [rootID, task.id]),
      root["deleted_at"] as String? == nil, root["resolved_at"] as String? == nil
    else {
      throw CommentError.invalid("Replies need an open, nondeleted thread.")
    }
    if draft.kind == "answer", root["kind"] as String != "question" {
      throw CommentError.invalid("An answer must reply to a question thread.")
    }
    return rootID
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

  private func commentCitation(
    _ source: String?, id: Int64, task: TaskDetails, at: Date, in tx: StorageTransaction
  ) throws {
    guard let source else { return }
    try tx.database.execute(
      sql: """
        INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,
          created_by,created_at)
        VALUES(?,?,'comment',?,'cites','note',?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: at), task.workspaceID, id, String(source.dropFirst(5)),
        environment.actor.description, Self.timestamp(at),
      ])
  }
}
