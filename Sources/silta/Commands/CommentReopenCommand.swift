import ArgumentParser
import SiltaCore

struct CommentReopenCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "reopen", abstract: "Reopen discussion threads atomically.")
  static let dataShape = CommentOutput.mutationShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @OptionGroup var body: TaskBody
  @Argument(help: "One or more thread refs; replies select their root.") var refs: [String]

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let command =
      "silta --ws " + shellWord(workspace) + " comment reopen "
      + refs.map { shellWord(SecretGuard.redacted($0)) }.joined(separator: " ")
    let explanation = try body.read(
      actor: context.environment.actor, command: command, approved: global.approved)
    let result = try TaskService(
      environment: context.environment, workspace: workspace,
      approved: global.approved, bodyFlag: body.flag
    ).updateComments(refs, action: .reopen, explanation: explanation, allowSecret: body.allowSecret)
    return CommentOutput.mutation(result).reporting(workspace)
  }
}
