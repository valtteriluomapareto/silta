import ArgumentParser
import SiltaCore

struct CommentAcceptCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "accept",
    abstract: "Accept an answer as the asker or current claimer and resolve the thread.")
  static let dataShape = CommentOutput.mutationShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @Argument(help: "The live answer ref to accept.") var ref: String

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try TaskService(environment: context.environment, workspace: workspace)
      .acceptComment(ref)
    return CommentOutput.mutation(result).reporting(workspace)
  }
}
