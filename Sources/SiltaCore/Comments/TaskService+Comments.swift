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
      let root = try replyRoot(draft, task: task, workspace: slug, in: tx.database)
      let (id, seq) = try insertComment(draft, task: task, root: root, at: at, in: tx)
      let commentRef = "\(task.ref)/\(seq)"
      let released = try touchDiscussion(
        task, handoff: draft.kind == "handoff", comment: commentRef, at: at, in: tx)
      if redacted {
        try changed(task.id, kind: "secret_redacted", body: commentRef, at: at, in: tx)
      }
      try tx.recordChange(kind: "comment", rowID: id)
      try consent?.record(
        command: audited(Self.commentCommand(task.ref, input, workspace: workspace))
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
        approvalUsed: consent != nil, released: released)
    }
  }

  func insertComment(
    _ draft: CommentDraft, task: TaskDetails, root: Int64? = nil, at: Date,
    in tx: StorageTransaction
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
    guard
      let recipients = String(bytes: try JSONEncoder().encode(draft.recipients), encoding: .utf8)
    else { throw StorageError.unavailable }
    try tx.database.execute(
      sql: """
        INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,mentions,actor,created_at)
        VALUES(?,?,?,?,?,?,?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: at), task.id, seq, root, draft.kind,
        draft.body, recipients,
        environment.actor.description,
        Self.timestamp(at),
      ])
    let id = tx.database.lastInsertedRowID
    if let source = draft.source {
      try tx.database.execute(
        sql: """
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,
            created_by,created_at)
          VALUES(?,?,'comment',?,'cites','note',?,?,?)
          """,
        arguments: [
          try environment.ids.next(at: at), task.workspaceID, id,
          String(source.dropFirst(5)), environment.actor.description, Self.timestamp(at),
        ])
      try tx.recordChange(kind: "link", rowID: tx.database.lastInsertedRowID)
    }
    return (id, seq)
  }

  func checkedComment(_ input: CommentDraft, command: String) throws -> (CommentDraft, Bool) {
    guard ["comment", "question", "answer", "decision", "handoff"].contains(input.kind) else {
      throw CommentError.invalid("Use comment, question, answer, decision or handoff.")
    }
    guard !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommentError.bodyRequired(command)
    }
    try Self.validateCommentBody(input.body)
    let body = try checked(input.body, allow: input.allowSecret, command: command + " -F <file>")
    try Self.validateCommentBody(body.0)
    var draft = input
    draft.body = body.0
    draft.recipients = try CommentRecipients.resolve(
      input.recipients, body: body.0, human: environment.human, question: input.kind == "question")
    if let source = input.source {
      guard source.hasPrefix("note:"),
        !source.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        SecretGuard.matches(in: source).isEmpty
      else {
        throw CommentError.invalid(
          "--from requires a nonempty, control-free note: reference without secrets.")
      }
    }
    return (draft, body.1)
  }

  /// A body-free command omitting defaults; a supplied workspace scopes recovery.
  package static func commentCommand(
    _ ref: String, _ draft: CommentDraft, workspace: String? = nil
  ) -> String {
    let scope = workspace.map { "--ws " + shellWord($0) + " " } ?? ""
    return "silta " + scope + "comment " + shellWord(SecretGuard.redacted(ref))
      + (draft.kind == "comment" && !draft.explicitKind
        ? "" : " --kind " + shellWord(SecretGuard.redacted(draft.kind)))
      + (draft.replyTo.map { " --reply-to " + shellWord(SecretGuard.redacted($0)) } ?? "")
      + draft.recipients.map { " --to " + shellWord(SecretGuard.redacted($0)) }.joined()
      + (draft.source.map { " --from " + shellWord(SecretGuard.redacted($0)) } ?? "")
  }

  private static func validateCommentBody(_ body: String) throws {
    guard body.unicodeScalars.count <= 8000 else {
      throw CommentError.invalid(
        "A comment is at most 8000 Unicode scalars; "
          + "summarize longer output and cite its file outside the repo."
      )
    }
  }

  func touchDiscussion(
    _ task: TaskDetails, handoff: Bool, comment: String, at: Date, in tx: StorageTransaction
  ) throws -> Bool {
    guard task.claimedBy == environment.actor.description else { return false }
    try tx.database.execute(
      sql: "UPDATE task SET claimed_by=?,claimed_at=?,updated_at=? WHERE id=?",
      arguments: [
        handoff ? nil : task.claimedBy, handoff ? nil : Self.timestamp(at), Self.timestamp(at),
        task.id,
      ])
    if handoff {
      try changed(task.id, kind: "claim", body: "released " + comment, at: at, in: tx)
    } else {
      try tx.recordChange(kind: "task", rowID: task.id)
    }
    return handoff
  }

}
