import ArgumentParser
import Foundation
import SiltaCore

struct AgentsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agents", abstract: "Preview and safely apply harness integration.",
    subcommands: [
      AgentsInstallCommand.self, AgentsUninstallCommand.self, AgentsSessionStartCommand.self,
      AgentsStopCommand.self,
    ])
  @OptionGroup(title: "Global Options") var global: GlobalOptions
}

struct AgentInstallOptions: ParsableArguments {
  @Flag(help: "Select Claude instructions and its shared OpenCode skill; default is both.")
  var claude = false
  @Flag(help: "Select Codex instructions and its writable root; default is both.") var codex =
    false
  @Flag(help: "Preview only; default is on.") var dryRun = false
  @Option(help: "Apply exactly this preview token; default is none.")
  var apply: String?
  @Flag(help: "Install Claude SessionStart; default is off.")
  var hook = false
  @Flag(help: "Install Claude Stop checks and SessionStart; default is off.")
  var stopHook = false

  func execute(_ context: CommandContext, uninstall: Bool) throws -> CommandOutput {
    let command = "silta agents " + (uninstall ? "uninstall" : "install")
    guard !(hook || stopHook) || (!uninstall && (claude || !codex)) else {
      throw UsageError.invalid(
        message: "--hook/--stop-hook require selected Claude during install; "
          + "uninstall removes all selected owned hooks without hook flags.", command: command)
    }
    guard !dryRun || apply == nil else {
      throw UsageError.invalid(message: "Choose --dry-run or --apply <token>.", command: command)
    }
    let selected =
      (claude ? " --claude" : "") + (codex ? " --codex" : "") + (hook ? " --hook" : "")
      + (stopHook ? " --stop-hook" : "")
    let preview = command + selected
    let files = try AgentInstallFiles(
      preview: preview, claude: claude || !codex, codex: codex || !claude)
    defer { files.close() }
    var targets = try AgentInstallTarget.selected(
      claude: claude || !codex, codex: codex || !claude,
      root: context.environment.home.url.path)
    if claude || !codex, hook || stopHook || uninstall {
      targets.append(
        AgentInstallTarget(
          path: ".claude/settings.json", body: "", whole: false,
          settings: true, stopHook: stopHook))
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
    discussion: "Defaults to Claude and Codex; preview exactly what --apply will write.\n"
      + "Retains unrelated content and file modes; refuses unsafe or ambiguous roots.\n"
      + "Replacements are atomic per file, not across files; failures list paths.\n"
      + "--hook opts into SessionStart; --stop-hook adds Stop and needs it.\n"
      + "Hook JSON needs exact safe integers; other forms need manual work.\n"
      + "Real harness acceptance is separate from installation.")
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = AgentInstallResult.shape
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var options: AgentInstallOptions
  func execute(_ context: CommandContext) throws -> CommandOutput {
    try options.execute(context, uninstall: false)
  }
}

struct AgentsUninstallCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall", abstract: "Preview removal of selected, unedited Silta ownership.",
    discussion: "Previews removal of only owned, unedited Silta content.\n"
      + "Defaults to Claude and Codex; --claude or --codex selects one.\n"
      + "Unrelated settings and hooks remain untouched.\n"
      + "Uninstall rejects --hook and --stop-hook; it removes selected hooks.\n"
      + "A changed preview token requires a fresh preview.")
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = AgentInstallResult.shape
  @OptionGroup(title: "Global Options") var global: GlobalOptions
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
