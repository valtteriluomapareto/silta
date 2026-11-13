import ArgumentParser
import SiltaCore

struct DocShowCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "Read a stored document revision, optionally selecting lines.")
  static let dataShape = Shape.object(["ref": .string, "output": .string])
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "Doc slug, doc:slug or doc:slug@revision.") var ref: String
  @Option(help: "Positive revision; must agree with a revision in the ref.") var rev: Int?
  @Option(help: "Positive rendered line N or inclusive range A-B; default is at most 400 lines.")
  var lines: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try DocService(workspace: workspace, store: context.environment.db)
      .show(ref, revision: rev, lines: lines)
    return CommandOutput(text: result.output, quiet: result.output, data: result).reporting(
      workspace)
  }
}
