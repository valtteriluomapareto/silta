import ArgumentParser
import Foundation
import SiltaCore

struct AgentsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agents", abstract: "Preview and safely apply harness integration.",
    subcommands: [
      AgentsInstallCommand.self, AgentsUninstallCommand.self, AgentsSessionStartCommand.self,
    ])
  @OptionGroup var global: GlobalOptions
}

struct AgentInstallOptions: ParsableArguments {
  @Flag(help: "Select Claude instructions and its shared OpenCode skill.") var claude = false
  @Flag(help: "Select Codex instructions and the effective SILTA_HOME writable root.") var codex =
    false
  @Flag(help: "Preview only (the default); never combine with --apply.") var dryRun = false
  @Option(help: "Apply exactly the preview identified by this token; no interactive prompt.")
  var apply: String?
  @Flag(help: "Install Claude SessionStart; uninstall removes owned hooks without this flag.")
  var hook = false

  func execute(_ context: CommandContext, uninstall: Bool) throws -> CommandOutput {
    let command = "silta agents " + (uninstall ? "uninstall" : "install")
    guard !hook || (!uninstall && (claude || !codex)) else {
      throw UsageError.invalid(
        message: "--hook requires selected Claude during install; "
          + "uninstall removes all selected owned hooks without hook flags.", command: command)
    }
    guard !dryRun || apply == nil else {
      throw UsageError.invalid(message: "Choose --dry-run or --apply <token>.", command: command)
    }
    let selected = (claude ? " --claude" : "") + (codex ? " --codex" : "") + (hook ? " --hook" : "")
    let preview = command + selected
    let files = try AgentInstallFiles(
      preview: preview, claude: claude || !codex, codex: codex || !claude)
    defer { files.close() }
    var targets = try AgentInstallTarget.selected(
      claude: claude || !codex, codex: codex || !claude,
      root: context.environment.home.url.path)
    if claude || !codex, hook || uninstall {
      targets.append(
        AgentInstallTarget(
          path: ".claude/settings.json", body: "", whole: false,
          settings: true))
    }
    let plan = try AgentInstallPlan(files: files, targets: targets, uninstall: uninstall)
    if let apply {
      guard apply == plan.token else {
        throw AgentInstallError(.conflict, "Preview changed; review a fresh diff.", next: [preview])
      }
      try files.apply(plan.edits)
    }
    let result = AgentInstallResult(
      applied: apply != nil, token: plan.token, changes: plan.edits.map(\.change))
    let diff = result.changes.map { "--- \($0.path)\n\($0.diff)" }.joined(separator: "\n")
    let text =
      (apply == nil ? "Preview" : "Applied") + ": \(result.changes.count) file(s).\n"
      + diff + (diff.isEmpty ? "" : "\n")
      + (apply == nil ? "Apply: \(preview) --apply \(plan.token)" : "")
    return CommandOutput(text: text, quiet: apply == nil ? text : "", data: result)
  }
}

struct AgentsInstallCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "install", abstract: "Preview owned harness edits; confirm with --apply <token>.",
    discussion: "Defaults to Claude and Codex. Unrelated content and file modes are retained. "
      + "Edited ownership, symlinks and ambiguous Codex root definitions are refused. "
      + "Replacements are atomic per file, not across files; a failure lists completed paths. "
      + "--hook opts into SessionStart; no hook flag leaves settings unread during install. "
      + "Hook JSON must have no duplicate keys and only exact safe-integer numbers; "
      + "other numeric forms require manual integration. Uninstall removes selected owned hooks. "
      + "Real harness acceptance is separate from installation.")
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = AgentInstallResult.shape
  @OptionGroup var global: GlobalOptions
  @OptionGroup var options: AgentInstallOptions
  func execute(_ context: CommandContext) throws -> CommandOutput {
    try options.execute(context, uninstall: false)
  }
}

struct AgentsUninstallCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall", abstract: "Preview removal of selected, unedited Silta ownership.",
    discussion: AgentsInstallCommand.configuration.discussion)
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = AgentInstallResult.shape
  @OptionGroup var global: GlobalOptions
  @OptionGroup var options: AgentInstallOptions
  func execute(_ context: CommandContext) throws -> CommandOutput {
    try options.execute(context, uninstall: true)
  }
}

struct AgentInstallResult: Encodable, Sendable {
  let applied: Bool
  let token: String
  let changes: [Change]
  struct Change: Encodable, Sendable {
    let path: String
    let diff: String
  }
  static let shape = Shape.object([
    "applied": .bool, "token": .string,
    "changes": .array(.object(["path": .string, "diff": .string])),
  ])
}
