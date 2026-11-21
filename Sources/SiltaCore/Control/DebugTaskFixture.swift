#if DEBUG
  package import Foundation
  import GRDB

  /// A synthetic task inserted without requiring a physical Git worktree.
  package struct DebugTaskFixture {
    package let sequence: Int64
    package let title: String
    package let app: String
    package let status: String
    package var creator = "agent:codex:fixture"
    package var claimant: String?
    package var plan = ""

    package init(_ sequence: Int64, _ title: String, app: String, status: String) {
      self.sequence = sequence
      self.title = title
      self.app = app
      self.status = status
    }

    /// Seeds complete owned rows in the caller's isolated fixture transaction.
    package func insert(in tx: StorageTransaction, ids: any IDGenerator, at: Date) throws {
      let db = tx.database
      guard
        let workspace = try Int64.fetchOne(db, sql: "SELECT id FROM workspace WHERE slug='acme'"),
        let appID = try Int64.fetchOne(
          db, sql: "SELECT id FROM app WHERE workspace_id=? AND slug=?",
          arguments: [workspace, app])
      else { throw StorageError.corrupt }
      let stamp = TaskService.timestamp(at)
      let author = claimant ?? creator
      try db.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,app_id,plan_md,plan_rev,
            claimed_by,claimed_at,branch,created_by,created_at,updated_at,
            closed_at,result_md,done_sha)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
          """,
        arguments: [
          try ids.next(at: at), workspace, sequence, title, status, appID, plan,
          plan.isEmpty ? 0 : 1, claimant, claimant == nil ? nil : stamp,
          claimant == nil ? nil : "feature/push", author, stamp, stamp,
          status == "done" ? stamp : nil,
          status == "done" ? "Implemented and verified the Acme change." : nil,
          status == "done" ? "1111111111111111111111111111111111111111" : nil,
        ])
      let id = db.lastInsertedRowID
      if !plan.isEmpty {
        try db.execute(
          sql: "INSERT INTO task_plan_rev(task_id,rev,body_md,actor,created_at) VALUES(?,1,?,?,?)",
          arguments: [id, plan, author, stamp])
      }
      let events = status == "review" ? ["created", "status"] : ["created"]
      for kind in events {
        try db.execute(
          sql: """
            INSERT INTO task_event(task_id,actor,kind,body,created_at) VALUES(?,?,?,?,?)
            """, arguments: [id, author, kind, status, stamp])
      }
      try db.execute(
        sql: """
          INSERT INTO seq_counter(scope,next) VALUES(?,?)
          ON CONFLICT(scope) DO UPDATE SET next=max(next,excluded.next)
          """, arguments: ["task:\(workspace)", sequence + 1])
      try tx.recordChange(kind: "task", rowID: id)
    }

    /// Sets the facts a fixture task shows beyond its row defaults; nil leaves a column as is.
    package static func annotate(
      _ sequence: Int64, acceptance: String? = nil, result: String? = nil,
      doneBranch: String? = nil, doneDirty: Bool? = nil, in tx: StorageTransaction
    ) throws {
      try tx.database.execute(
        sql: """
          UPDATE task SET acceptance_md=coalesce(?,acceptance_md),result_md=coalesce(?,result_md),
            done_branch=coalesce(?,done_branch),done_dirty=coalesce(?,done_dirty)
          WHERE seq=? AND workspace_id=(SELECT id FROM workspace WHERE slug='acme')
          """, arguments: [acceptance, result, doneBranch, doneDirty, sequence])
      guard tx.database.changesCount == 1 else { throw StorageError.corrupt }
      try tx.recordChange(kind: "task", rowID: try id(sequence, in: tx))
    }

    private static func id(_ sequence: Int64, in tx: StorageTransaction) throws -> Int64 {
      guard
        let id = try Int64.fetchOne(
          tx.database,
          sql: "SELECT id FROM task WHERE seq=? AND workspace_id=(SELECT id FROM workspace "
            + "WHERE slug='acme')",
          arguments: [sequence])
      else { throw StorageError.corrupt }
      return id
    }

    /// Moves a fixture claim's heartbeat, so the claim reads as live or expired.
    package static func claim(_ sequence: Int64, heartbeat: Date, in tx: StorageTransaction) throws {
      try tx.database.execute(
        sql: """
          UPDATE task SET claimed_at=? WHERE seq=? AND claimed_by IS NOT NULL
            AND workspace_id=(SELECT id FROM workspace WHERE slug='acme')
          """, arguments: [TaskService.timestamp(heartbeat), sequence])
      guard tx.database.changesCount == 1 else { throw StorageError.corrupt }
    }

    /// Completes a fixture task that other fixture writes needed open, such as a blocker.
    package static func complete(_ sequence: Int64, in tx: StorageTransaction, at: Date) throws {
      let stamp = TaskService.timestamp(at)
      try tx.database.execute(
        sql: """
          UPDATE task SET status='done',closed_at=?,updated_at=?,result_md=?,done_sha=?
          WHERE seq=? AND workspace_id=(SELECT id FROM workspace WHERE slug='acme')
          """,
        arguments: [
          stamp, stamp, "Implemented and verified the Acme change.",
          "1111111111111111111111111111111111111111", sequence,
        ])
      guard tx.database.changesCount == 1 else { throw StorageError.corrupt }
    }
  }
#endif
