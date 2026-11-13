import ArgumentParser
import SiltaCore

struct DocListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List current documents and pending revisions.")
  static let dataShape = Shape.object([
    "entries": .array(.object(["ref": .string, "state": .string, "output": .string])),
    "total": .int, "offset": .int, "limit": .int, "next": .optional(.string),
  ])
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Option(help: "Filter by a canonical app, edge, service or topic ref.") var about: String?
  @Flag(help: "Include archived documents.") var archived = false
  @Option(help: "Number of entries to skip.") var offset = 0
  @Option(help: "Number of entries, from 1 to 100.") var limit = 20

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    let result = try DocService(workspace: workspace, store: context.environment.db)
      .list(about: about, archived: archived, offset: offset, limit: limit)
    return CommandOutput(text: result.output, quiet: result.output, data: result).reporting(
      workspace)
  }
}
