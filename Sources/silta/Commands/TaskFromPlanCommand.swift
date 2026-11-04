import ArgumentParser
import Foundation
import SiltaCore

struct TaskFromPlanCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "from-plan",
    abstract: "Import Markdown steps; preview or safely remove the source.")

  static let dataShape = Shape.object([
    "dry_run": .bool,
    "preview": .object([
      "title": .string, "description": .string, "status": .string, "app": .optional(.string),
      "steps": .array(
        .object(["title": .string, "description": .string, "status": .optional(.string)])),
    ]), "tasks": .array(TaskOutput.receiptShape),
  ])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "UTF-8 Markdown file, or - for stdin (the default).") var file = "-"

  @Option(help: "The existing parent task reference; created tasks inherit its app.")
  var parent: String?

  @Flag(help: "Create at most ten subtasks instead of a checklist.") var split = false

  @Flag(help: "Preview content and statuses without creating tasks.") var dryRun = false

  @Flag(help: "Remove an unchanged untracked source after commit; never a harness file.")
  var delete = false

  @Flag(help: "Retain detected secrets (human-only).") var allowSecret = false

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    var options = TaskImport()
    options.parent = parent
    options.split = split
    options.dryRun = dryRun
    options.delete = delete
    options.allowSecret = allowSecret
    // A dry run stores nothing, so --allow-secret on it needs no approval.
    if allowSecret, !dryRun {
      try context.environment.actor.requireHuman(
        command: options.retryCommand + " --allow-secret", approved: global.approved)
    }
    let text = try read()
    let result = try await TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved
    )
    .fromPlan(
      text, options: options, source: file == "-" ? nil : URL(filePath: file),
      directory: URL(
        filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory))
    let preview = result.preview
    var lines =
      result.dryRun
      ? ["Preview: \(preview.status): \(preview.title)"]
      : result.tasks.map {
        "\($0.ref) \($0.status)"
      }
    if result.dryRun {
      if let app = preview.app { lines.append("App: \(app)") }
      let description = preview.description.trimmingCharacters(in: .newlines)
      if !description.isEmpty { lines += ["", description] }
      lines += ["", split ? "Subtasks:" : "Checklist:"]
      for (index, step) in preview.steps.enumerated() {
        lines.append("\(index + 1). " + (step.status.map { $0 + ": " } ?? "") + step.title)
        let detail = step.description.trimmingCharacters(in: .newlines)
        if !detail.isEmpty { lines.append(detail) }
      }
    }
    let shown = lines.joined(separator: "\n")
    let unused =
      result.dryRun && global.approved != nil
      ? [
        OutputWarning(
          code: "approval_unused",
          message: "A dry run records nothing, so --approved was not used; no approval stored.")
      ] : []
    return CommandOutput(
      text: shown,
      quiet: result.dryRun ? shown : result.tasks.map(\.ref).joined(separator: "\n"),
      data: result, warnings: result.warnings + unused,
      approvalUsed: result.approvalUsed
    ).reporting(context.taskWorkspace(global.ws))
  }

  private func read() throws -> String {
    do {
      let data =
        try file == "-"
        ? FileHandle.standardInput.readToEnd() ?? Data()
        : Data(contentsOf: URL(filePath: file))
      guard let text = String(data: data, encoding: .utf8) else { throw TaskError.input }
      return text
    } catch { throw TaskError.input }
  }
}
