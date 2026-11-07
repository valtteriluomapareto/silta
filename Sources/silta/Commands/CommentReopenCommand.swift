import ArgumentParser
import SiltaCore

struct CommentReopenCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "reopen", abstract: "Reopen discussion threads atomically.")
  static let dataShape = CommentOutput.mutationShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var input: CommentThreadOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    try input.execute(context, global: global, action: .reopen)
  }
}
