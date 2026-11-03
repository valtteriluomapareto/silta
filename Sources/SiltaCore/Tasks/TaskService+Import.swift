package import Foundation

extension TaskService {
  /// Parses, previews or atomically imports a plan; cleanup never precedes commit.
  package func fromPlan(
    _ text: String, options: TaskImport = TaskImport(), source: URL? = nil, directory: URL
  ) async throws -> TaskImportResult {
    let approval = try approval(
      required: options.allowSecret, command: options.retryCommand + " --allow-secret")
    guard !options.delete || !options.dryRun && source != nil else {
      throw TaskError.invalid("--delete requires a real file and cannot be used with --dry-run.")
    }
    let content = try checked(
      text, allow: options.allowSecret, command: options.retryCommand)
    let parsed = try MarkdownPlan(content.0)
    if options.split, parsed.steps.count > 10 {
      throw TaskError.invalid("--split accepts at most 10 steps; keep a checklist or shorten it.")
    }
    let preview = try importPreview(parsed, options: options)
    if options.dryRun {
      return TaskImportResult(
        dryRun: true, preview: preview, tasks: [],
        warnings: content.1 ? [SecretGuard.warning] : [])
    }
    let cleanup = try await sourceToDelete(text, options: options, source: source, in: directory)
    let slug = try selected()
    let creations = try importCreations(parsed, options: options, redacted: content.1)
    let result = try environment.db.write { tx in
      let root = try insert(creations[0], workspace: slug, in: tx)
      var tasks = [root]
      if options.split {
        for var child in creations.dropFirst() {
          child.draft.parent = root.ref
          tasks.append(try insert(child, workspace: slug, in: tx))
        }
      } else {
        let task = try Self.lookup(root.ref, workspace: slug, in: tx.database)
        try writePlan(parsed.checklist, task: task, redacted: false, at: creations[0].at, in: tx)
      }
      try approval?.record(
        command: options.auditCommand(created: tasks), workspace: slug,
        identity: (environment.ids, creations[0].at), in: tx)
      let actualPreview = try importPreview(parsed, options: options, rootStatus: root.status)
      return TaskImportResult(
        dryRun: false, preview: actualPreview, tasks: tasks,
        warnings: content.1 ? [SecretGuard.warning] : [])
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

  private func importPreview(
    _ plan: MarkdownPlan, options: TaskImport, rootStatus: String? = nil
  ) throws -> TaskImportPreview {
    let task = try rootStatus == nil ? options.parent.map { try show($0) } : nil
    return TaskImportPreview(
      title: plan.title, description: plan.description,
      status: rootStatus ?? creationStatus(parent: task),
      steps: plan.steps.map {
        TaskImportStep(
          title: $0.title, description: $0.description,
          status: options.split ? (environment.actor.isHuman ? "todo" : "proposed") : nil)
      })
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
