import Foundation
import GRDB

extension TaskService {
  /// The `doc_gap` hint for a task's app, read inside the write that triggers it. It
  /// appears once per task: at the first submit or owner's handoff, counting the current
  /// one. Owner handoffs are the ones that released a claim.
  func docGapWarning(_ task: TaskDetails, workspace: String, in db: Database) throws
    -> OutputWarning?
  {
    guard let appID = task.appID,
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM task_event WHERE task_id=:task
            AND ((kind='claim' AND body LIKE 'released %') OR (kind='status' AND body='review'))
          """, arguments: ["task": task.id]) == 1
    else { return nil }
    return DocGaps.warning(
      try DocGaps.appEdges(
        appID: appID, workspaceID: try Self.workspaceID(workspace, in: db), in: db),
      workspace: workspace, task: task.ref)
  }
}
