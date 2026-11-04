/// Options for turning a Markdown file into task work.
package struct TaskImport: Sendable {
  /// Names an existing parent task, if the import belongs to one.
  package var parent: String?

  /// Creates at most ten child tasks instead of a checklist.
  package var split = false

  /// Returns a secret-checked preview without writing or deleting anything.
  package var dryRun = false

  /// Removes a safely validated source only after successful creation.
  package var delete = false

  /// Retains detected secrets with the human's go-ahead.
  package var allowSecret = false

  /// A body-free retry preserves the options that determine the import result.
  package var retryCommand: String {
    "silta task from-plan <file>" + commandOptions
  }

  /// The flags actually passed, then the created refs, without the source body or path.
  func auditCommand(created: [TaskResult]) -> String {
    "silta task from-plan" + commandOptions + (allowSecret ? " --allow-secret" : "") + " -> "
      + created.map(\.ref).joined(separator: " ")
  }

  private var commandOptions: String {
    var command = ""
    if let parent { command += " --parent " + shellWord(parent) }
    if split { command += " --split" }
    if dryRun { command += " --dry-run" }
    if delete { command += " --delete" }
    return command
  }

  /// Starts with a non-destructive checklist import.
  package init() {}
}

/// A parsed step with the status it would receive when split into a child task.
package struct TaskImportStep: Encodable, Sendable {
  /// The child's title.
  package let title: String

  /// Text following the step, including nested content.
  package let description: String

  /// The child creation status when splitting; absent for checklist entries.
  package let status: String?
}

/// The content and intended statuses shown before and after an import.
package struct TaskImportPreview: Encodable, Sendable {
  /// The first Markdown heading.
  package let title: String

  /// Text before the first step, excluding the title heading.
  package let description: String

  /// The root task's intended creation status.
  package let status: String

  /// The parsed top-level steps in source order.
  package let steps: [TaskImportStep]
}

/// An import result distinguishes preview from committed task references.
package struct TaskImportResult: Encodable, Sendable {
  /// Whether this call only parsed and checked the input.
  package let dryRun: Bool

  /// The parsed content with secrets handled before output.
  package let preview: TaskImportPreview

  /// Real committed references; empty for a preview.
  package let tasks: [TaskResult]

  /// Secret policy, preview consent and postcommit cleanup warnings.
  package var warnings: [OutputWarning] = []

  /// Whether the import recorded consent; never encoded or used by a preview.
  package var approvalUsed = false

  enum CodingKeys: String, CodingKey {
    case preview, tasks
    case dryRun = "dry_run"
  }
}
