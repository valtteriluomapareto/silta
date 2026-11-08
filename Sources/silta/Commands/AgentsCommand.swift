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

struct AgentInstallInput {
  var uninstall = false
  var claude = false
  var codex = false
  var dryRun = false
  var apply: String?
  var hook = false
  var stopHook = false
}

struct AgentInstallOptions: ParsableArguments {
  @Flag(help: "Select Claude instructions and its shared OpenCode skill; default is both.")
  var claude = false
  @Flag(help: "Select Codex instructions and its SILTA_HOME writable root; default is both.")
  var codex =
    false
  @Flag(help: "Preview only (the default); never combine with --apply.") var dryRun = false
  @Option(help: "Apply exactly the preview identified by this token; no interactive prompt.")
  var apply: String?
  @Flag(help: "Install Claude SessionStart.")
  var hook = false
  @Flag(help: "Install Claude Stop handoff checks and the required SessionStart hook.")
  var stopHook = false

  func execute(_ context: CommandContext, uninstall: Bool) throws -> CommandOutput {
    var input = AgentInstallInput()
    input.uninstall = uninstall
    input.claude = claude
    input.codex = codex
    input.dryRun = dryRun
    input.apply = apply
    input.hook = hook
    input.stopHook = stopHook
    return try Self.run(context, input: input)
  }

  static func run(_ context: CommandContext, input: AgentInstallInput) throws -> CommandOutput {
    let command = "silta agents " + (input.uninstall ? "uninstall" : "install")
    let apply = input.apply
    try validateHooks(input, command: command)
    guard !input.dryRun || input.apply == nil else {
      throw UsageError.invalid(message: "Choose --dry-run or --apply <token>.", command: command)
    }
    let selected =
      (input.claude ? " --claude" : "") + (input.codex ? " --codex" : "")
      + (input.hook ? " --hook" : "") + (input.stopHook ? " --stop-hook" : "")
    let preview = command + selected
    let files = try AgentInstallFiles(
      preview: preview, claude: input.claude || !input.codex, codex: input.codex || !input.claude)
    defer { files.close() }
    var targets = try AgentInstallTarget.selected(
      claude: input.claude || !input.codex, codex: input.codex || !input.claude,
      root: context.environment.home.url.path)
    if input.claude || !input.codex, input.hook || input.stopHook || input.uninstall {
      targets.append(
        AgentInstallTarget(
          path: ".claude/settings.json", body: "", whole: false,
          settings: true, stopHook: input.stopHook))
    }
    let plan = try AgentInstallPlan(files: files, targets: targets, uninstall: input.uninstall)
    if let apply = input.apply {
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

  private static func validateHooks(_ input: AgentInstallInput, command: String) throws {
    guard !input.uninstall || !(input.hook || input.stopHook) else {
      throw UsageError.invalid(
        message: "--hook/--stop-hook require selected Claude during install; "
          + "uninstall removes all selected owned hooks without hook flags.", command: command)
    }
    guard !(input.hook || input.stopHook) || (input.claude || !input.codex) else {
      throw UsageError.invalid(
        message: "--hook/--stop-hook require selected Claude during install.", command: command)
    }
  }
}

struct AgentsInstallCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "install", abstract: "Preview owned harness edits; confirm with --apply <token>.",
    discussion: "Defaults to Claude and Codex; preview exactly what --apply will write.\n"
      + "Retains unrelated content and file modes; refuses unsafe or ambiguous roots.\n"
      + "Replacements are atomic per file, not across files; failures list paths.\n"
      + "--hook opts into SessionStart; no hook leaves settings unread.\n"
      + "Hook JSON needs exact safe integers; other forms need manual work.\n"
      + "Real harness acceptance is separate from installation.\n"
      + "Preview harness changes: silta agents install\n"
      + "Apply reviewed preview: silta agents install --apply PREVIEW_TOKEN")
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = AgentInstallResult.shape
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var options: AgentInstallOptions
  func execute(_ context: CommandContext) throws -> CommandOutput {
    try options.execute(context, uninstall: false)
  }
}

struct AgentUninstallOptions: ParsableArguments {
  @Flag(help: "Select Claude instructions and its shared OpenCode skill; default is both.")
  var claude = false
  @Flag(help: "Select Codex instructions and its SILTA_HOME writable root; default is both.")
  var codex = false
  @Flag(help: "Preview only (the default); never combine with --apply.") var dryRun = false
  @Option(help: "Apply exactly the preview identified by this token; no interactive prompt.")
  var apply: String?
  @Flag(help: .hidden) var hook = false
  @Flag(help: .hidden) var stopHook = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var input = AgentInstallInput()
    input.uninstall = true
    input.claude = claude
    input.codex = codex
    input.dryRun = dryRun
    input.apply = apply
    input.hook = hook
    input.stopHook = stopHook
    return try AgentInstallOptions.run(context, input: input)
  }
}

struct AgentsUninstallCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall", abstract: "Preview removal of selected, unedited Silta ownership.",
    discussion: "Previews removal of only owned, unedited Silta content.\n"
      + "Defaults to Claude and Codex; --claude or --codex selects one.\n"
      + "Unrelated settings and hooks remain untouched.\n"
      + "Uninstall removes selected hooks without extra hook flags.\n"
      + "A changed preview token requires a fresh preview.")
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = AgentInstallResult.shape
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var options: AgentUninstallOptions
  func execute(_ context: CommandContext) throws -> CommandOutput {
    try options.execute(context)
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
