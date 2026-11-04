package import Foundation

extension TaskService {
  /// Parses, previews or atomically imports a plan; cleanup never precedes commit. A
  /// preview stores nothing, so `--allow-secret` on it needs no approval.
  package func fromPlan(
    _ text: String, options: TaskImport = TaskImport(), source: URL? = nil, directory: URL
  ) async throws -> TaskImportResult {
    let approval = try approval(
      required: options.allowSecret && !options.dryRun,
      command: options.retryCommand + " --allow-secret")
    let (parsed, redacted) = try preparedImport(text, options: options, source: source)
    let preview = try importPreview(parsed, options: options)
    let warnings = redacted ? [SecretGuard.warning] : []
    if options.dryRun {
      return try dryRun(parsed, options: options, preview: preview, warnings: warnings)
    }
    let cleanup = try await sourceToDelete(text, options: options, source: source, in: directory)
    let slug = try selected()
    let creations = try importCreations(parsed, options: options, redacted: redacted)
    let result = try environment.db.write { tx in
      let retry = (scopedCommand(options.retryCommand, workspace: slug), nil as String?)
      let inserted = try insert(
        creations[0], workspace: slug, retry: retry, count: creations.count, in: tx)
      let root = inserted.task
      var tasks = [root]
      if options.split {
        for var child in creations.dropFirst() {
          child.draft.parent = root.ref
          tasks.append(
            try insert(
              child, workspace: slug, status: Self.childStatus(root.status), in: tx
            ).task)
        }
      } else {
        let task = try Self.lookup(root.ref, workspace: slug, in: tx.database)
        try writePlan(parsed.checklist, task: task, redacted: false, at: creations[0].at, in: tx)
      }
      let used = approval ?? inserted.approval
      try used?.record(
        command: options.auditCommand(created: tasks), workspace: slug,
        identity: (environment.ids, creations[0].at), in: tx)
      let actualPreview = try importPreview(parsed, options: options, rootStatus: root.status)
      return TaskImportResult(
        dryRun: false, preview: actualPreview, tasks: tasks, warnings: warnings,
        approvalUsed: used != nil)
    }
    guard let cleanup else { return result }
    var completed = result
    if !(await cleanup.removeIfUnchanged(runner: environment.git)) {
      completed.warnings.append(
        OutputWarning(
          code: "source_retained",
          message:
            "Tasks committed; source was retained. Inspect it and remove it manually if safe."))
    }
    return completed
  }

  private func dryRun(
    _ plan: MarkdownPlan, options: TaskImport, preview: TaskImportPreview,
    warnings: [OutputWarning]
  ) throws -> TaskImportResult {
    var result = TaskImportResult(dryRun: true, preview: preview, tasks: [], warnings: warnings)
    guard preview.status == "proposed" else { return result }
    let policy: WorkspaceSettings.Proposals?
    do {
      let slug = try selected()
      policy = try environment.db.read {
        try WorkspaceSettings.read(workspaceID: Self.workspaceID(slug, in: $0), in: $0).proposals
      }
    } catch WorkspaceError.notFound where workspace == nil {
      policy = nil
    }
    if approved != nil || policy == .ask {
      result = TaskImportResult(
        dryRun: true, preview: try importPreview(plan, options: options, rootStatus: "todo"),
        tasks: [], warnings: warnings)
    }
    if approved == nil, policy == .ask {
      let count = options.split ? plan.steps.count + 1 : 1
      result.warnings.append(
        OutputWarning(
          code: "proposal_approval_required",
          message: "This workspace sets proposals: ask; the real run needs the human's go-ahead "
            + "in chat and will create \(count) task\(count == 1 ? "" : "s") as todo."))
    }
    return result
  }

  private func preparedImport(_ text: String, options: TaskImport, source: URL?) throws
    -> (MarkdownPlan, Bool)
  {
    guard !options.delete || !options.dryRun && source != nil else {
      throw TaskError.invalid("--delete requires a real file and cannot be used with --dry-run.")
    }
    let content = try importContent(text, options: options)
    let parsed = try MarkdownPlan(content.0)
    if options.split, parsed.steps.count > 10 {
      throw TaskError.invalid("--split accepts at most 10 steps; keep a checklist or shorten it.")
    }
    return (parsed, content.1)
  }

  /// The plan text after the secret guard; a dry run keeps it with `--allow-secret`,
  /// unapproved, since it stores nothing.
  private func importContent(_ text: String, options: TaskImport) throws -> (String, Bool) {
    if options.dryRun && options.allowSecret { return (text, false) }
    return try checked(text, allow: options.allowSecret, command: options.retryCommand)
  }

  private func importPreview(
    _ plan: MarkdownPlan, options: TaskImport, rootStatus: String? = nil
  ) throws -> TaskImportPreview {
    let task =
      try rootStatus == nil
      ? options.parent.map { ref in try Self.named("parent") { try show(ref) } } : nil
    if let task { try Self.validateParent(task) }
    let status = rootStatus ?? creationStatus(parent: task)
    return TaskImportPreview(
      title: plan.title, description: plan.description, status: status,
      steps: plan.steps.map {
        TaskImportStep(
          title: $0.title, description: $0.description,
          status: options.split ? Self.childStatus(status) : nil)
      })
  }

  /// Split children follow the root, decided once per import: a proposal's steps are
  /// proposals too, and the steps of authorized work are `todo`.
  static func childStatus(_ root: String) -> String {
    root == "proposed" ? "proposed" : "todo"
  }

  private func importCreations(_ plan: MarkdownPlan, options: TaskImport, redacted: Bool) throws
    -> [TaskCreation]
  {
    var draft = TaskDraft(title: plan.title)
    draft.description = plan.description
    draft.parent = options.parent
    draft.allowSecret = options.allowSecret
    var root = try prepare(draft, command: options.retryCommand)
    root.redacted = redacted
    var creations = [root]
    if options.split {
      for step in plan.steps {
        draft.title = step.title
        draft.description = step.description
        var child = try prepare(draft, command: options.retryCommand)
        child.redacted = redacted
        creations.append(child)
      }
    }
    return creations
  }

  private func sourceToDelete(
    _ text: String, options: TaskImport, source: URL?, in directory: URL
  ) async throws -> PlanSource? {
    guard options.delete, let source else { return nil }
    return try await PlanSource.validate(
      source, content: Data(text.utf8), directory: directory, runner: environment.git)
  }
}
