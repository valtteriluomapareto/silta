import ArgumentParser
import Foundation
import SiltaCore

struct BriefCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "brief", abstract: "Read budgeted local context for the current task.",
    discussion: "An explicit budget overrides the 2500-token default (800 for short/hook). "
      + "Tiny budgets retain location, task reference, settings and complete more commands. "
      + "Hook mode has a 1.5 s process deadline and silently succeeds on errors; it never "
      + "fetches, indexes or migrates. The current task shows its newest handoff, your inbox "
      + "items on it and an open-question count; your other inbox items follow it. "
      + "Decisions are absent from the brief.\n"
      + "Read task context: silta brief --task AC-1")
  static let workspaceSource = WorkspaceSource.location
  static let dataShape = Shape.object([
    "location": .object([
      "workspace": .string, "repo": .string, "app": .any, "branch": .any,
      "confidence": .string, "reason": .string,
    ]),
    "settings": .object([
      "ask_about": .optional(.string), "proposals": .optional(.string),
      "review_gate": .optional(.string),
      "archive_after_days": .optional(.int), "stale_days": .optional(.int),
    ]),
    "current_task": .optional(.string),
    "sections": .array(.object(["id": .string, "text": .string])),
    "more": .array(.string), "truncated": .bool,
  ])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Option(help: "Select one of this repository's candidate apps; default is inferred.") var app:
    String?
  @Option(help: "Read this task; default is session or branch evidence.") var task: String?
  @Option(help: "Add context for a topic slug or alias; default is none. Repeat to add topics.")
  var topic: [String] = []
  @Option(
    help: .init(
      "Positive token budget, estimated as rendered characters / 4; "
        + "default is 2500, or 800 with --short/--hook."))
  var budget: Int?
  @Flag(help: "Use an 800-token brief.") var short = false
  @Flag(help: "Read bounded session-start context, silently ignoring errors.") var hook = false
  var appSlug: String? { app }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    guard budget == nil || (budget ?? 0) > 0 else {
      throw UsageError.invalid(message: "Budget must be positive.", command: "silta brief")
    }
    let report = try await BriefService(environment: context.environment).resolve(
      path: URL(filePath: FileManager.default.currentDirectoryPath), workspace: global.ws,
      app: app, task: task, topics: topic, budget: budget ?? (short || hook ? 800 : 2500),
      hook: hook)
    return CommandOutput(
      text: report.text, quiet: report.text, data: report, warnings: report.warnings
    )
    .reporting(report.location.workspace)
  }
}
