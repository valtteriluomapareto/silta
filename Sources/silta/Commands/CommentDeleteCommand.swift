import ArgumentParser
import SiltaCore

struct CommentDeleteCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete", abstract: "Soft-delete your own post, retaining its ref and thread.")
  static let dataShape = CommentOutput.mutationShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "The exact post to delete, including a root or reply.") var ref: String

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try TaskService(environment: context.environment, workspace: workspace)
      .updateComments([ref], action: .delete)
    return CommentOutput.mutation(result).reporting(workspace)
  }
}
