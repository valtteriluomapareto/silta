import GRDB

extension TaskDetails {
  init(row: Row) {
    id = row["id"]
    workspaceID = row["workspace_id"]
    appID = row["app_id"]
    repoPath = row["repo_path"]
    ref = "\(row["task_prefix"] as String)-\(row["seq"] as Int64)"
    parent = (row["parent_seq"] as Int64?).map { "\(row["task_prefix"] as String)-\($0)" }
    title = row["title"]
    status = row["status"]
    description = row["description_md"]
    acceptance = row["acceptance_md"]
    priority = row["priority"]
    archiveOverride = row["archive_override"]
    externalRef = row["external_ref"]
    closedAt = row["closed_at"]
    followUpAt = row["follow_up_at"]
    result = row["result_md"]
    plan = row["plan_md"]
    planRev = row["plan_rev"]
    createdBy = row["created_by"]
    createdAt = row["created_at"]
    updatedAt = row["updated_at"]
    claimedBy = row["claimed_by"]
    claimedAt = row["claimed_at"]
    app = row["app_slug"]
    branch = row["branch"]
    worktree = row["worktree"]
    doneSHA = row["done_sha"]
    doneBranch = row["done_branch"]
    doneDirty = row["done_dirty"]
  }
}
