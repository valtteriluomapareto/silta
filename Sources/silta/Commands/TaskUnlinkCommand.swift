import ArgumentParser
import SiltaCore

struct TaskUnlinkCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "unlink", abstract: "Remove one task link to a workspace map item.",
    discussion: "Use the exact relation and target shown by task show. "
      + "An absent link to an existing map target returns removed=false. "
      + "Blockers belong to task block.\n"
      + "Remove an Acme map link: silta task unlink AC-1 app:api --rel about")

  static let dataShape = Shape.object(["ref": .string, "status": .string, "removed": .bool])
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "The source task reference.") var ref: String
  @Argument(help: "The app, topic, edge or service reference.") var target: String
  @Option(help: "The link relation.")
  var rel = "cites"

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let (receipt, removed) = try TaskService(
      environment: context.environment, workspace: global.ws
    ).unlink(ref, target: target, relation: rel)
    let link = rel + " " + TaskError.shown(receipt.target ?? target)
    let change = removed ? "unlinked " + link : "no matching link " + link
    return CommandOutput(
      text: TaskOutput.receiptText(receipt, change: change),
      data: Receipt(ref: receipt.ref, status: receipt.status, removed: removed),
      warnings: receipt.warnings
    ).reporting(context.taskWorkspace(global.ws))
  }

  private struct Receipt: Encodable {
    let ref: String
    let status: String
    let removed: Bool
  }
}
