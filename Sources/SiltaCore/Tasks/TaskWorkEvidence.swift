import Foundation
import GRDB

/// Optional local Git evidence for the CLI task detail and ordinary brief.
package struct TaskWorkEvidence: Encodable, Sendable {
  enum Reachability: String, Encodable, Sendable {
    case reachable
    case unreachable = "not_reachable"
    case unknown
  }

  let commits: [TaskWorkCommit]
  let branch: TaskWorkBranch?
  let omittedCommits: Int?
  package let warnings: [OutputWarning]

  enum CodingKeys: String, CodingKey {
    case commits, branch
    case omittedCommits = "omitted_commits"
  }

  package var lines: [String] {
    var lines = commits.map { commit in
      let state = commit.state.rawValue.replacingOccurrences(of: "_", with: " ")
      let anchor = commit.ref.map { " from " + $0 } ?? ""
      let tip = commit.tipSHA.map { " at " + $0 } ?? ""
      let fetched = commit.fetchedAt.map { " (last recorded fetch " + $0 + ")" } ?? ""
      let basis =
        commit.ref?.hasPrefix("refs/remotes/") == true ? "cached tracking ref" : "local clone"
      return "commit: \(commit.target) \(state)\(anchor)\(tip) (\(basis))\(fetched)"
    }
    if let branch {
      let state = branch.state.replacingOccurrences(of: "_", with: " ")
      let tip = branch.tipSHA.map { " at " + $0 } ?? ""
      lines.append("branch: \(branch.name) (\(branch.source)) \(state)\(tip) in cached clone")
    }
    if let omittedCommits {
      lines.append("\(omittedCommits) additional linked commits outside the evidence budget")
    }
    return lines
  }
}

struct TaskWorkCommit: Encodable, Sendable {
  let target: String
  let ref: String?
  let tipSHA: String?
  let fetchedAt: String?
  let state: TaskWorkEvidence.Reachability

  enum CodingKeys: String, CodingKey {
    case target, ref, state
    case tipSHA = "tip_sha"
    case fetchedAt = "fetched_at"
  }
}

struct TaskWorkBranch: Encodable, Sendable {
  let name: String
  let source: String
  var state: String
  let tipSHA: String?

  enum CodingKeys: String, CodingKey {
    case name, source, state
    case tipSHA = "tip_sha"
  }
}

/// Captures storage identities once before optional subprocess work starts.
struct TaskEvidenceInput: Sendable {
  private struct Commit: Sendable {
    let identity: TaskCommitReference
    let repo: TaskEvidenceRepo?
  }

  private struct Branch: Sendable {
    let name: String
    let source: String
    var fromClaim: Bool { source == "claim" }
    let repo: TaskEvidenceRepo?
  }

  private let commits: [Commit]
  private let branch: Branch?
  private let workspace: String
  private let now: Date

  static func read(_ task: TaskDetails, workspace: String, at now: Date, in db: Database) throws
    -> Self?
  {
    let commits = try linkedCommits(task, in: db)
    let branch = try branch(task, at: now, in: db)
    guard !commits.isEmpty || branch != nil else { return nil }
    return Self(commits: commits, branch: branch, workspace: workspace, now: now)
  }

  private static func linkedCommits(_ task: TaskDetails, in db: Database) throws -> [Commit] {
    let links = try String.fetchAll(
      db,
      sql: """
        SELECT to_ext FROM link WHERE workspace_id=? AND from_kind='task' AND from_id=?
          AND to_kind='code' AND anchor IS NULL AND substr(to_ext,-2)=':.' ORDER BY id
        """, arguments: [task.workspaceID, task.id])
    var seen = Set<String>()
    return try links.compactMap { link in
      guard let identity = TaskCommitReference("code:" + link, requireRootPath: true),
        RestoreService.canNameInRecovery(identity.app)
      else { return nil }
      let owner = try WorkspaceSlugs.resolve(
        .app, identity.app, workspace: task.workspaceID, in: db)
      let key = (owner?.slug ?? identity.app) + "@" + identity.sha
      guard seen.insert(key).inserted else { return nil }
      let repo = try owner.flatMap {
        try repository(app: $0.id, workspace: task.workspaceID, in: db)
      }
      return Commit(identity: identity, repo: repo)
    }
  }

  private static func branch(_ task: TaskDetails, at now: Date, in db: Database) throws -> Branch? {
    guard let app = task.appID else { return nil }
    let repository = try repository(app: app, workspace: task.workspaceID, in: db)
    if task.status == "doing", task.claimedBy != nil, let heartbeat = task.claimedAt,
      let expiry = try? TaskService.claimExpiry(heartbeat),  // A corrupt lease is not fresh.
      now < expiry
    {
      guard let name = task.branch, TaskEvidenceGit.isLiteralBranch(name) else { return nil }
      return Branch(name: name, source: "claim", repo: repository)
    }
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT seq, body_md FROM comment WHERE task_id=? AND kind='handoff'
            AND deleted_at IS NULL AND thread_id IS NULL ORDER BY created_at DESC, id DESC LIMIT 1
          """, arguments: [task.id]),
      let name = handoffBranch(row["body_md"])
    else { return nil }
    return Branch(name: name, source: task.ref + "/" + String(row["seq"] as Int), repo: repository)
  }

  private static func handoffBranch(_ body: String) -> String? {
    guard body.prefix(16_384).endIndex == body.endIndex,
      SecretGuard.matches(in: body).isEmpty
    else { return nil }
    let lines = body.components(separatedBy: "\n")
    let names = MarkdownPlan.visibleLines(lines).compactMap { index -> String? in
      let raw = lines[index]
      let content = raw.drop(while: { $0 == " " })
      let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !raw.hasPrefix("    "), !content.hasPrefix("\t"), !line.hasPrefix(">") else {
        return nil
      }
      let name: Substring
      if let found = line.wholeMatch(of: /Branch:[ \t]+(\S+)/) {
        name = found.1
      } else if let found = line.firstMatch(
        of: /(?:^|;[ \t]*)Branch and sha:[ \t]+(\S+)[ \t]+at[ \t]+([0-9a-fA-F]+)\.?$/
      ), TaskCommitReference.isFullSHA(found.2) {
        name = found.1
      } else {
        return nil
      }
      let branch = String(name)
      return TaskEvidenceGit.isLiteralBranch(branch) ? branch : nil
    }
    return Set(names).count == 1 ? names.first : nil
  }

  private static func repository(app: Int64, workspace: Int64, in db: Database) throws
    -> TaskEvidenceRepo?
  {
    try Row.fetchOne(
      db,
      sql: """
        SELECT repo.id,repo.slug,app.ref,repo_path.path,repo_path.fetched_at
        FROM app JOIN repo ON repo.id=app.repo_id
        LEFT JOIN repo_path ON repo_path.repo_id=repo.id
        WHERE app.id=? AND app.workspace_id=? AND repo.workspace_id=?
        """, arguments: [app, workspace, workspace]
    ).map { row in
      TaskEvidenceRepo(
        id: row["id"], name: row["slug"], path: row["path"], appRef: row["ref"],
        fetchedAt: row["fetched_at"])
    }
  }

  func inspect(using runner: any GitRunner) async -> TaskWorkEvidence {
    var git = TaskEvidenceGit(runner: runner)
    let branchTip =
      if let branch {
        await git.tip(branch.name, repo: branch.repo, localOnly: branch.fromClaim)
      } else {
        TaskEvidenceGit.Tip.unknown
      }
    var branchState = branchResult(at: branchTip)
    var warnings = branchWarnings(at: branchTip)
    var evidence: [TaskWorkCommit] = []
    var warnedRepos = Set<Int64>()
    for commit in commits.prefix(3) {
      let tip = await git.configuredTip(commit.repo)
      let state = await git.reachability(commit.identity.sha, at: tip, repo: commit.repo)
      evidence.append(Self.commitResult(commit, at: tip, state: state))
      if let repo = commit.repo, Self.observedTrackingRef(tip, repo: repo) != nil,
        warnedRepos.insert(repo.id).inserted,
        let warning = fetchWarning(repo, missing: tip == .missing)
      {
        warnings.append(warning)
      }
      if let branch, let repo = branch.repo, commit.repo?.id == repo.id,
        case .found = branchTip
      {
        let state = await git.reachability(commit.identity.sha, at: branchTip, repo: repo)
        if state == .unreachable {
          branchState?.state = "missing_commit"
          warnings.append(Self.missingCommitWarning(branch, commit: commit.identity.sha))
        } else if state == .unknown, branchState?.state != "missing_commit" {
          branchState?.state = "unknown"
        }
      }
    }
    return TaskWorkEvidence(
      commits: evidence, branch: branchState,
      omittedCommits: commits.count > evidence.count ? commits.count - evidence.count : nil,
      warnings: warnings)
  }

  private static func commitResult(
    _ commit: Commit, at tip: TaskEvidenceGit.Tip, state: TaskWorkEvidence.Reachability
  ) -> TaskWorkCommit {
    let target = "code:" + commit.identity.stored
    guard case .found(let ref, let sha) = tip else {
      let tracking = commit.repo.flatMap { observedTrackingRef(tip, repo: $0) }
      return .init(target: target, ref: tracking, tipSHA: nil, fetchedAt: nil, state: state)
    }
    return .init(
      target: target, ref: ref, tipSHA: sha,
      fetchedAt: ref.hasPrefix("refs/remotes/") ? commit.repo?.fetchedAt.map(HumanText.line) : nil,
      state: state)
  }

  private static func observedTrackingRef(_ tip: TaskEvidenceGit.Tip, repo: TaskEvidenceRepo)
    -> String?
  {
    if case .found(let ref, _) = tip, ref.hasPrefix("refs/remotes/") { return ref }
    if tip == .missing, repo.appRef.hasPrefix("refs/remotes/") { return repo.appRef }
    return nil
  }

  private static func missingCommitWarning(_ branch: Branch, commit: String) -> OutputWarning {
    .init(
      code: "task_branch_lacks_commit",
      message: "Branch \(branch.name) from \(HumanText.line(branch.source)) lacks linked "
        + "commit \(commit) in the cached clone.")
  }

  private func branchResult(at tip: TaskEvidenceGit.Tip) -> TaskWorkBranch? {
    guard let branch else { return nil }
    let source = HumanText.line(branch.source)
    switch tip {
    case .found(_, let sha):
      return .init(name: branch.name, source: source, state: "present", tipSHA: sha)
    case .missing: return .init(name: branch.name, source: source, state: "missing", tipSHA: nil)
    case .unknown: return .init(name: branch.name, source: source, state: "unknown", tipSHA: nil)
    }
  }

  private func branchWarnings(at tip: TaskEvidenceGit.Tip) -> [OutputWarning] {
    guard let branch, tip == .missing else { return [] }
    return [
      .init(
        code: "task_branch_missing",
        message: "Branch \(branch.name) from \(HumanText.line(branch.source)) is missing "
          + "in the registered clone.")
    ]
  }

  private func fetchWarning(_ repo: TaskEvidenceRepo, missing: Bool) -> OutputWarning? {
    if !missing, let raw = repo.fetchedAt,
      let date = try? Date(raw, strategy: .iso8601),  // An unreadable fetch time is unknown.
      now.timeIntervalSince(date) < 86_400
    {
      return nil
    }
    guard RestoreService.canNameInRecovery(workspace), RestoreService.canNameInRecovery(repo.name)
    else { return nil }
    let command = workspaceCommand("silta repo fetch " + shellWord(repo.name), workspace: workspace)
    return .init(
      code: "ref_stale",
      message:
        "Tracking-ref freshness is unverified. For current remote evidence run `\(command)`, "
        + "then read the task again.")
  }
}

extension TaskService {
  /// Adds Git evidence only on the explicit CLI read path.
  package func showWithWorkEvidence(_ ref: String, timeline: Bool = false) async throws
    -> TaskDetails
  {
    let slug = try selected()
    let (task, work) = try environment.db.read { db in
      let task = try read(ref, workspace: slug, timeline: timeline, in: db)
      let input = try? TaskEvidenceInput.read(  // Optional evidence must not hide task detail.
        task, workspace: slug, at: environment.clock.now(), in: db)
      return (task, input)
    }
    var result = task
    result.workEvidence = await work?.inspect(using: environment.git)
    return result
  }
}
