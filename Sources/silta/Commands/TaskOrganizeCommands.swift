import ArgumentParser
import SiltaCore

struct TaskArchiveCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "archive",
    abstract: "Hide a task from the default backlog.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String
  func execute(_ context: CommandContext) throws -> CommandOutput {
    TaskOutput.receipt(
      try TaskService(environment: context.environment, workspace: global.ws)
        .archive(ref)
    ).reporting(context.taskWorkspace(global.ws))
  }
}

struct TaskKeepCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "keep",
    abstract: "Keep a task visible regardless of its closed age.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String
  func execute(_ context: CommandContext) throws -> CommandOutput {
    TaskOutput.receipt(
      try TaskService(environment: context.environment, workspace: global.ws)
        .archive(ref, keep: true)
    ).reporting(context.taskWorkspace(global.ws))
  }
}

struct TaskLinkCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "link",
    abstract: "Link a task to a reference in this workspace or an external URL.")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The source task reference.")
  var ref: String

  @Argument(help: "The target reference (task, doc, app, topic, code, plan, note or url).")
  var target: String

  @Option(help: "The relation; defaults to cites. blocked_by belongs to block.")
  var rel = "cites"
  func execute(_ context: CommandContext) throws -> CommandOutput {
    TaskOutput.receipt(
      try TaskService(environment: context.environment, workspace: global.ws)
        .link(ref, target: target, relation: rel)
    ).reporting(context.taskWorkspace(global.ws))
  }
}

struct TaskPromoteCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "promote",
    abstract: "Record an external tracker and make the task read-only (human-only).")

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String

  @Option(help: "ado:<id>, gh:<owner>/<repo>#<id> or jira:<KEY>-<id>.")
  var ext: String
  func execute(_ context: CommandContext) throws -> CommandOutput {
    TaskOutput.receipt(
      try TaskService(
        environment: context.environment, workspace: global.ws,
        approved: global.approved
      ).promote(ref, external: ext), approvalUsed: true
    ).reporting(context.taskWorkspace(global.ws))
  }
}
