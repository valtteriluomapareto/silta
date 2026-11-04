package import Foundation
import GRDB

extension TaskService {
  /// Creates a task, its initial claim and its links in one transaction.
  /// App work records the current worktree; no-app work never invokes git.
  package func add(_ draft: TaskDraft, directory: URL) async throws -> TaskResult {
    let approval = try approval(
      required: draft.allowSecret, command: draft.command + " '<title>' -F <file> --allow-secret")
    var creation = try prepare(draft, command: draft.command + " '<title>' -F <file>")
    let slug = try selected()
    creation = try resolved(creation, workspace: slug)
    creation.git = try await inspected(creation, draft: draft, directory: directory)
    let prepared = creation
    return try environment.db.write { tx in
      let command = prepared.draft.command + (draft.allowSecret ? " --allow-secret" : "")
      let retry =
        scopedCommand(command, workspace: slug)
        + (bodyFlag == nil ? "" : " -F <file>")
      let inserted = try insert(
        prepared, workspace: slug, retry: (retry, prepared.draft.title), in: tx)
      var result = inserted.task
      let used = approval ?? inserted.approval
      result.approvalUsed = used != nil
      try used?.record(
        command: audited(command) + " -> " + result.ref, workspace: slug,
        identity: (environment.ids, prepared.at), in: tx)
      return result
    }
  }

  func prepare(_ draft: TaskDraft, command: String) throws -> TaskCreation {
    let title = try checked(draft.title, allow: draft.allowSecret, command: command)
    let body = try checked(draft.description, allow: draft.allowSecret, command: command)
    let source = try draft.source.map {
      try checked($0, allow: draft.allowSecret, command: command)
    }
    try validateDraft(draft)
    var safe = draft
    safe.title = title.0
    safe.description = body.0
    safe.source = source?.0
    let at = environment.clock.now()
    return TaskCreation(
      draft: safe, uid: try environment.ids.next(at: at), at: at,
      redacted: title.1 || body.1 || source?.1 == true)
  }

  /// Inserts prepared work and decides proposal consent in this transaction. Split
  /// children inherit an already-decided root status without recording extra consent.
  func insert(
    _ creation: TaskCreation, workspace: String, status override: String? = nil,
    retry: (command: String, title: String?)? = nil, count: Int = 1,
    in tx: StorageTransaction
  ) throws -> (task: TaskResult, approval: HumanApproval?) {
    let draft = creation.draft
    let db = tx.database
    let ws = try Self.workspaceID(workspace, in: db)
    let parent = try draft.parent.map { ref in
      try Self.named("parent") { try Self.lookup(ref, workspace: workspace, in: db) }
    }
    if let parent { try Self.validateParent(parent) }
    if draft.app == nil, let parent, parent.app != creation.app {
      throw TaskError.changed(parent.ref)
    }
    let app = try creation.app.map {
      try Self.entity("app", slug: $0, workspace: ws, in: db)
    }
    if let app, try Self.repoPath(app: app, in: db) != creation.path {
      throw TaskError.changed(nil)
    }
    var status = override ?? creationStatus(parent: parent, start: draft.start)
    var consent: HumanApproval?
    if override == nil, status == "proposed" {
      let retry = retry ?? (scopedCommand(draft.command, workspace: workspace), draft.title)
      let policy = try WorkspaceSettings.read(workspaceID: ws, in: db).proposals
      if policy == .ask, approved == nil {
        throw ActorError.proposalPolicy(
          command: retry.command, actor: environment.actor, title: retry.title, count: count)
      }
      consent = try approval(required: approved != nil, command: retry.command)
      if consent != nil { status = "todo" }
    }
    let seq = try tx.nextSequence(scope: "task:\(ws)")
    let stamp = Self.timestamp(creation.at)
    try db.execute(
      sql: """
        INSERT INTO task(uid,workspace_id,seq,title,status,priority,description_md,parent_id,app_id,
          claimed_by,claimed_at,branch,worktree,created_by,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """,
      arguments: [
        creation.uid, ws, seq, draft.title, status, draft.priority, draft.description, parent?.id,
        app,
        draft.start ? environment.actor.description : nil, draft.start ? stamp : nil,
        creation.git.branch, creation.git.worktree, environment.actor.description, stamp, stamp,
      ])
    let id = db.lastInsertedRowID
    try addLinks(draft, task: id, workspace: ws, at: creation.at, in: db)
    try changed(
      id, kind: "created", body: status, redacted: creation.redacted, at: creation.at, in: tx)
    return (try created(creation, seq: seq, status: status, workspace: ws, in: db), consent)
  }

  /// The created task's receipt; an inherited app is named in its text, not its data.
  private func created(
    _ creation: TaskCreation, seq: Int64, status: String, workspace: Int64, in db: Database
  ) throws -> TaskResult {
    TaskResult(
      ref: "\(try Self.prefix(workspace, in: db))-\(seq)", status: status,
      warnings: creation.redacted ? [SecretGuard.warning] : [],
      inheritedApp: creation.draft.app == nil ? creation.app : nil)
  }

  func creationStatus(parent: TaskDetails?, start: Bool = false) -> String {
    if start { return "doing" }
    return environment.actor.isHuman || parent?.claimedBy == environment.actor.description
      ? "todo" : "proposed"
  }

  /// Git values for the worktree; app work outside the app's repository is refused with
  /// the app named and where it came from.
  private func inspected(
    _ creation: TaskCreation, draft: TaskDraft, directory: URL
  ) async throws -> TaskGit {
    do {
      return try await TaskGit.inspect(
        repo: creation.path, directory: directory, runner: environment.git,
        enabled: draft.start && creation.app != nil, completion: false)
    } catch let error as TaskError where Self.outsideRepository(error, directory: directory) {
      guard let app = creation.app, let path = creation.path else { throw error }
      throw TaskError.outsideAppRepo(
        app, repo: path,
        origin: draft.app == nil ? draft.parent.map { "inherited from \($0)" } : nil)
    }
  }

  /// App work from another repository, or from above no repository at all. A git that
  /// cannot run stays an environment error for a human.
  private static func outsideRepository(_ error: TaskError, directory: URL) -> Bool {
    error == .foreignRepo || error == .git && !insideWorktree(directory)
  }

  /// Whether a worktree root is at or above `directory`; both `.git` forms mark one.
  private static func insideWorktree(_ directory: URL) -> Bool {
    var url = directory.standardizedFileURL
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return true }
      url = url.deletingLastPathComponent()
    }
    return false
  }

  /// The creation with the app it takes and that app's repository, both resolved
  /// before any git work so the write can compare against them.
  func resolved(_ creation: TaskCreation, workspace: String) throws -> TaskCreation {
    var resolved = creation
    let parent = try parent(creation.draft, workspace: workspace)
    resolved.app = appSlug(creation.draft, parent: parent)
    resolved.path = try appPath(resolved.app, workspace: workspace)
    return resolved
  }

  /// The parent a creation names, validated before git runs so a closed parent fails
  /// as a parent error.
  private func parent(_ draft: TaskDraft, workspace: String) throws -> TaskDetails? {
    guard let ref = draft.parent else { return nil }
    return try environment.db.read { db in
      let parent = try Self.named("parent") { try Self.lookup(ref, workspace: workspace, in: db) }
      try Self.validateParent(parent)
      return parent
    }
  }

  /// The app a creation takes: an explicit one (`none` means non-code work), or the
  /// parent's when `--app` is absent.
  private func appSlug(_ draft: TaskDraft, parent: TaskDetails?) -> String? {
    switch draft.app {
    case nil: return parent?.app
    case TaskDraft.noneApp?: return nil
    case let app?: return app
    }
  }

  private func appPath(_ app: String?, workspace: String) throws -> String? {
    try app.flatMap { app in
      try environment.db.read { db in
        let ws = try Self.workspaceID(workspace, in: db)
        let id = try Self.entity("app", slug: app, workspace: ws, in: db)
        return try Self.repoPath(app: id, in: db)
      }
    }
  }

  private func validateDraft(_ draft: TaskDraft) throws {
    try Self.validatePriority(draft.priority)
    try Self.validateTitle(draft.title)
    if let source = draft.source, !source.hasPrefix("note:") || source.count == 5 {
      throw TaskError.invalid("--from requires a note: reference.")
    }
  }

  /// A parent is open and unpromoted, so a subtask never hangs off finished or tracked work.
  static func validateParent(_ parent: TaskDetails) throws {
    if ["done", "dropped"].contains(parent.status) || parent.externalRef != nil {
      throw TaskError.invalid("A parent must be an open task that is not promoted.")
    }
  }

  /// A title is one nonblank line, so it can't fake rows in line-based output.
  static func validateTitle(_ title: String) throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TaskError.invalid("A task title is required.")
    }
    if title.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
      throw TaskError.invalid("A task title is one line without control characters.")
    }
  }

  private func addLinks(
    _ draft: TaskDraft, task: Int64, workspace: Int64, at date: Date, in db: Database
  ) throws {
    for topic in Set(draft.topics).sorted() {
      let id = try Self.entity("topic", slug: topic, workspace: workspace, in: db)
      try insertLink(
        task: task, workspace: workspace, target: ("topic", id.databaseValue), at: date, in: db)
    }
    if let source = draft.source {
      try insertLink(
        task: task, workspace: workspace,
        target: ("note", String(source.dropFirst(5)).databaseValue), at: date, in: db)
    }
  }

  func insertLink(
    task: Int64, workspace: Int64, target: (String, DatabaseValue),
    at date: Date, in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,to_ext,
          created_by,created_at)
        VALUES(?,?,'task',?,?,?,?,?,?,?)
        """,
      arguments: [
        try environment.ids.next(at: date), workspace, task,
        target.0 == "note" ? "source" : "about", target.0, target.0 == "note" ? nil : target.1,
        target.0 == "note" ? target.1 : nil,
        environment.actor.description, Self.timestamp(date),
      ])
  }

  static func prefix(_ workspace: Int64, in db: Database) throws -> String {
    guard
      let value = try String.fetchOne(
        db, sql: "SELECT task_prefix FROM workspace WHERE id=?", arguments: [workspace])
    else { throw WorkspaceError.notFound }
    return value
  }

  static func repoPath(app: Int64, in db: Database) throws -> String? {
    try String.fetchOne(
      db,
      sql: """
        SELECT repo_path.path
        FROM app
        LEFT JOIN repo_path ON repo_path.repo_id=app.repo_id
        WHERE app.id=?
        """, arguments: [app])
  }
}
