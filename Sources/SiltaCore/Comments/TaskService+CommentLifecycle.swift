import Foundation
import GRDB

extension TaskService {
  /// Mutates discussion atomically. Resolve/reopen normalize to roots; delete targets
  /// exactly the named post and requires its author. No-ops write nothing.
  package func updateComments(
    _ refs: [String], action: CommentAction, explanation: String? = nil, allowSecret: Bool = false
  ) throws -> CommentMutationResult {
    guard !refs.isEmpty, action != .delete || (refs.count == 1 && explanation == nil)
    else {
      throw CommentError.invalid("Name thread refs; delete takes one post and no explanation.")
    }
    guard explanation != nil || !allowSecret else {
      throw CommentError.invalid("--allow-secret needs an explanation from -m or -F.")
    }
    let slug = try selected(), at = environment.clock.now()
    let command = action.command(refs)
    return try environment.db.write { tx in
      let targets = try commentTargets(refs, action: action, workspace: slug, in: tx.database)
      var result = CommentMutationResult(
        action: action.receipt, refs: targets.map { "\($0.0.ref)/\($0.1["seq"] as Int)" })
      let changed = targets.filter { Self.commentChanges($0.1, action: action) }
      result.unchanged = targets.filter { !Self.commentChanges($0.1, action: action) }
        .map { "\($0.0.ref)/\($0.1["seq"] as Int)" }
      if changed.isEmpty { return result }
      let consent = try approval(
        required: allowSecret,
        command: scopedCommand(command, workspace: slug) + " --allow-secret -F <file>")
      let safe = try checkedExplanation(
        explanation, allowSecret: allowSecret, command: scopedCommand(command, workspace: slug))
      var touched: Set<Int64> = []
      for (task, row) in changed {
        let id: Int64 = row["id"]
        try setCommentState(row, task: task, action: action, at: at, in: tx)
        if let (draft, redacted) = safe {
          let (postID, seq) = try insertComment(draft, task: task, root: id, at: at, in: tx)
          let ref = "\(task.ref)/\(seq)"
          result.created.append(ref)
          try tx.recordChange(kind: "comment", rowID: postID)
          if redacted {
            try self.changed(task.id, kind: "secret_redacted", body: ref, at: at, in: tx)
          }
        }
        if touched.insert(task.id).inserted {
          _ = try touchDiscussion(
            task, handoff: false, comment: "\(task.ref)/\(row["seq"] as Int)", at: at, in: tx)
        }
      }
      try consent?.record(
        command: audited(command) + " --allow-secret -> " + result.created.joined(separator: " "),
        workspace: slug, identity: (environment.ids, at), in: tx)
      result.approvalUsed = consent != nil
      result.warnings = safe?.1 == true ? [SecretGuard.warning] : []
      return result
    }
  }

  private func checkedExplanation(
    _ text: String?, allowSecret: Bool, command: String
  ) throws -> (CommentDraft, Bool)? {
    guard let text else { return nil }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommentError.explanationEmpty(command)
    }
    var draft = CommentDraft(body: text)
    draft.allowSecret = allowSecret
    return try checkedComment(draft, command: command)
  }

  private func commentTargets(
    _ refs: [String], action: CommentAction, workspace: String, in db: Database
  ) throws -> [(TaskDetails, Row)] {
    var targets: [(TaskDetails, Row)] = [], seen: Set<Int64> = []
    for ref in refs {
      let (task, post) = try Self.commentTarget(ref, workspace: workspace, in: db)
      var row = post
      try Self.mutable(task)
      if action == .delete {
        guard row["actor"] as String == environment.actor.description else {
          let resolved = (row["root_resolved_at"] as String?) ?? (row["resolved_at"] as String?)
          throw CommentError.wrongAuthor(
            author: row["actor"], actor: environment.actor.description,
            root: resolved == nil
              ? "\(task.ref)/\((row["root_seq"] as Int?) ?? (row["seq"] as Int))" : nil,
            task: task.ref)
        }
      } else if let root = row["thread_id"] as Int64? {
        guard
          let found = try Row.fetchOne(
            db, sql: Self.commentQuery + " WHERE c.id=? AND c.task_id=?",
            arguments: [root, task.id])
        else { throw StorageError.unavailable }
        row = found
      }
      if seen.insert(row["id"]).inserted { targets.append((task, row)) }
    }
    return targets
  }

  private static func commentChanges(_ row: Row, action: CommentAction) -> Bool {
    switch action {
    case .resolve: row["resolved_at"] as String? == nil
    case .reopen: row["resolved_at"] as String? != nil
    case .delete: row["deleted_at"] as String? == nil
    }
  }

  private func setCommentState(
    _ row: Row, task: TaskDetails, action: CommentAction, at: Date, in tx: StorageTransaction
  ) throws {
    let id: Int64 = row["id"]
    switch action {
    case .resolve:
      try tx.database.execute(
        sql: "UPDATE comment SET resolved_at=?,resolved_by=? WHERE id=?",
        arguments: [Self.timestamp(at), environment.actor.description, id])
    case .reopen:
      let accepted = try Int64.fetchAll(
        tx.database, sql: "SELECT id FROM comment WHERE (id=? OR thread_id=?) AND accepted<>0",
        arguments: [id, id])
      try tx.database.execute(
        sql: "UPDATE comment SET accepted=0 WHERE id=? OR thread_id=?", arguments: [id, id])
      for answer in accepted { try tx.recordChange(kind: "comment", rowID: answer) }
      try tx.database.execute(
        sql: "UPDATE comment SET resolved_at=NULL,resolved_by=NULL WHERE id=?", arguments: [id])
    case .delete:
      try tx.database.execute(
        sql: "UPDATE comment SET deleted_at=? WHERE id=?", arguments: [Self.timestamp(at), id])
    }
    try tx.recordChange(kind: "comment", rowID: id)
    if action != .delete {
      try changed(
        task.id, kind: "discussion", body: "\(action.receipt) \(task.ref)/\(row["seq"] as Int)",
        at: at, in: tx)
    }
  }

  static func commentTarget(_ raw: String, workspace: String, in db: Database) throws
    -> (TaskDetails, Row)
  {
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let seq = Int(parts[1]), seq > 0, String(seq) == parts[1] else {
      throw CommentError.invalid("Use a canonical task comment ref such as AC-1/2.")
    }
    let task = try Self.lookup(String(parts[0]), workspace: workspace, in: db)
    guard
      let row = try Row.fetchOne(
        db, sql: commentQuery + " WHERE c.task_id=? AND c.seq=?", arguments: [task.id, seq])
    else { throw CommentError.missing("\(task.ref)/\(seq)", task.ref) }
    return (task, row)
  }
}
