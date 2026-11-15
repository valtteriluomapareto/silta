import Foundation
import GRDB

extension DocProposalService {
  func source(
    _ request: DocProposalRequest, workspace: String, id: Int64, at: Date, in db: Database
  ) throws -> Int64? {
    if let ref = request.task {
      let task: TaskDetails
      do { task = try TaskService.lookup(ref, workspace: workspace, in: db) } catch let error
        as TaskError
      {
        throw CommandFailure(
          error: error,
          next: [
            workspaceCommand(
              "silta task ls --proposed --promoted --archived", workspace: workspace)
          ])
      }
      return task.id
    }
    let rows = try Int64.fetchAll(
      db,
      sql: """
        SELECT id FROM task
        WHERE workspace_id=? AND claimed_by=? AND status='doing' AND claimed_at>?
        ORDER BY id
        """,
      arguments: [
        id, environment.actor.description,
        utcTimestamp(at.addingTimeInterval(-TaskService.claimDuration)),
      ])
    guard rows.count <= 1 else { throw DocError.missing(["--task"]) }
    return rows.first
  }
}
