import ArgumentParser
import Foundation
import SiltaCore

struct BriefCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "brief", abstract: "Read budgeted local context for the current task.",
    discussion: "An explicit budget overrides the 2500-token default (800 for short/hook). "
      + "Tiny budgets retain location, task reference, settings and complete more commands. "
      + "Hook mode has a 1.5 s process deadline and silently succeeds on errors; it never "
      + "fetches, indexes or migrates. App/backlog and discussion sections are not yet included.")
  static let workspaceSource = WorkspaceSource.option
  static let dataShape = Shape.object([
    "location": .object([
      "workspace": .string, "repo": .string, "app": .optional(.string), "branch": .any,
      "confidence": .string, "reason": .string,
    ]),
    "settings": .object([
      "proposals": .optional(.string), "review_gate": .optional(.string),
      "archive_after_days": .optional(.int), "stale_days": .optional(.int),
    ]),
    "current_task": .optional(.string),
    "sections": .array(.object(["id": .string, "text": .string])),
    "more": .array(.string), "truncated": .bool,
  ])

  @OptionGroup var global: GlobalOptions
  @Option(help: "Select one of the repository's candidate apps.") var app: String?
  @Option(help: "Read this task before session or branch task evidence.") var task: String?
  @Option(help: "Positive token budget, estimated as rendered characters / 4.") var budget: Int?
  @Flag(help: "Default to an 800-token brief.") var short = false
  @Flag(help: "Read bounded session-start context, silently ignoring errors.") var hook = false
  var appSlug: String? { app }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    guard budget == nil || (budget ?? 0) > 0 else {
      throw UsageError.invalid(message: "Budget must be positive.", command: "silta brief")
    }
    let report = try await BriefService(environment: context.environment).resolve(
      path: URL(filePath: FileManager.default.currentDirectoryPath), workspace: global.ws,
      app: app, task: task, budget: budget ?? (short || hook ? 800 : 2500), hook: hook)
    return CommandOutput(text: report.text, quiet: report.text, data: report)
      .reporting(report.location.workspace)
  }
}
