import ArgumentParser
import SiltaCore

struct CommentResolveCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "resolve", abstract: "Resolve discussion threads atomically.")
  static let dataShape = CommentOutput.mutationShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @OptionGroup var input: CommentThreadOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    try input.execute(context, global: global, action: .resolve)
  }
}
