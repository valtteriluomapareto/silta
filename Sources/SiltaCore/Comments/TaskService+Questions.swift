import GRDB

extension TaskService {
  func replyRoot(_ draft: CommentDraft, task: TaskDetails, workspace: String, in db: Database)
    throws
    -> Int64?
  {
    guard let ref = draft.replyTo else {
      if draft.kind == "answer" {
        throw CommentError.invalid("An answer requires --reply-to a question.")
      }
      return nil
    }
    guard ["comment", "decision", "answer"].contains(draft.kind) else {
      throw CommentError.invalid("Questions and handoffs must be roots; omit --reply-to.")
    }
    let (target, post) = try Self.commentTarget(ref, workspace: workspace, in: db)
    guard target.id == task.id else {
      throw CommentError.invalid("A reply must belong to the selected task.")
    }
    let root = try Self.threadRoot(post, task: task, in: db)
    try Self.liveThread(post, root: root, task: task)
    if draft.kind == "answer", root["kind"] as String != "question" {
      throw CommentError.invalid("An answer must reply to a question.")
    }
    return root["id"]
  }

  /// Selects a live answer as the question asker or current task claimer and resolves its thread.
  /// Repeating the selected live acceptance writes nothing; reopen enables a new selection.
  package func acceptComment(_ ref: String) throws -> CommentMutationResult {
    let workspace = try selected(), at = environment.clock.now()
    return try environment.db.write { tx in
      let (task, answer) = try Self.commentTarget(ref, workspace: workspace, in: tx.database)
      try Self.mutable(task)
      let root = try Self.threadRoot(answer, task: task, in: tx.database)
      guard answer["kind"] as String == "answer", answer["thread_id"] as Int64? != nil,
        root["kind"] as String == "question"
      else { throw CommentError.answerRequired(task.ref) }
      guard
        Self.canAcceptAnswer(
          answer["actor"], asker: root["actor"], claimer: task.claimedBy,
          caller: environment.actor.description)
      else {
        if answer["actor"] as String == environment.actor.description,
          task.claimedBy == environment.actor.description
        {
          throw CommentError.unavailable(
            "A claimer cannot accept its own answer to another actor's question.",
            task: task.ref, reopen: nil)
        }
        throw CommentError.wrongAsker(
          asker: root["actor"], actor: environment.actor.description, task: task.ref,
          root: root["resolved_at"] as String? == nil ? "\(task.ref)/\(root["seq"] as Int)" : nil)
      }
      try Self.liveThread(answer, root: root, task: task, allowResolved: true)
      let answerRef = "\(task.ref)/\(answer["seq"] as Int)"
      var result = CommentMutationResult(action: "accepted", refs: [answerRef])
      if answer["accepted"] as Bool, root["resolved_at"] as String? != nil {
        result.unchanged = [answerRef]
        return result
      }
      try Self.liveThread(answer, root: root, task: task)
      let rootID: Int64 = root["id"], answerID: Int64 = answer["id"]
      try tx.database.execute(
        sql: "UPDATE comment SET accepted=1 WHERE id=?", arguments: [answerID])
      try tx.database.execute(
        sql: "UPDATE comment SET resolved_at=?,resolved_by=? WHERE id=?",
        arguments: [Self.timestamp(at), environment.actor.description, rootID])
      try tx.recordChange(kind: "comment", rowID: answerID)
      try tx.recordChange(kind: "comment", rowID: rootID)
      try changed(task.id, kind: "discussion", body: "accepted " + answerRef, at: at, in: tx)
      _ = try touchDiscussion(task, handoff: false, comment: answerRef, at: at, in: tx)
      return result
    }
  }

  static func canAcceptAnswer(_ author: String, asker: String, claimer: String?, caller: String)
    -> Bool
  {
    asker == caller || (claimer == caller && author != caller)
  }

  private static func threadRoot(_ post: Row, task: TaskDetails, in db: Database) throws -> Row {
    guard let root = post["thread_id"] as Int64? else { return post }
    guard
      let row = try Row.fetchOne(
        db, sql: commentQuery + " WHERE c.id=? AND c.task_id=?", arguments: [root, task.id])
    else { throw StorageError.corrupt }
    return row
  }

  private static func liveThread(
    _ post: Row, root: Row, task: TaskDetails, allowResolved: Bool = false
  ) throws {
    guard post["deleted_at"] as String? == nil, root["deleted_at"] as String? == nil else {
      throw CommentError.unavailable(
        "Deleted posts cannot receive replies or acceptance.", task: task.ref, reopen: nil)
    }
    if !allowResolved, root["resolved_at"] as String? != nil {
      throw CommentError.unavailable(
        "This thread is resolved; reopen it before replying or selecting another answer.",
        task: task.ref, reopen: "\(task.ref)/\(root["seq"] as Int)")
    }
  }
}
