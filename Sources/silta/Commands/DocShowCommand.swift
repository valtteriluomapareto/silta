import ArgumentParser
import SiltaCore

struct DocShowCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "Read stored revisions, diffs or paged comments.")
  static let dataShape = Shape.object(["ref": .string, "output": .string])
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "Doc slug, doc:slug or doc:slug@revision[/comment].") var ref: String
  @Option(help: "Positive revision; must agree with a revision in the ref.") var rev: Int?
  @Option(help: "Positive rendered line N or inclusive range A-B; default is at most 400 lines.")
  var lines: String?
  @Flag(help: "Compare against the recorded base revision.") var diff = false
  @Flag(help: "Read revision comments.") var comments = false
  @Option(help: "Comment entries to skip; requires --comments; default is 0.") var offset: Int?
  @Option(help: "Comment entries, from 1 to 20; requires --comments; default is 20.") var limit:
    Int?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try DocService(workspace: workspace, store: context.environment.db)
      .show(
        ref, revision: rev, lines: lines, diff: diff, comments: comments, offset: offset,
        limit: limit)
    return CommandOutput(text: result.output, quiet: result.output, data: result).reporting(
      workspace)
  }
}
