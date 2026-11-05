import ArgumentParser
import Foundation
import SiltaCore

struct ExportCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Write one workspace as a deterministic text tree for backup and diff.",
    discussion:
      "The tree goes to <root>/<workspace>. It replaces only an absent, empty or previously "
      + "exported directory, never one inside a registered repo. Machine paths are not written.")

  static let dataShape = Shape.object(["workspace": .string, "path": .string, "files": .int])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Option(help: "The export root; defaults to $SILTA_HOME/exports.")
  var to: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    let workspace = try context.workspace(global.ws)
    let root =
      to.map { URL(filePath: $0, directoryHint: .isDirectory, relativeTo: .currentDirectory()) }
      ?? environment.home.url.appending(path: "exports", directoryHint: .isDirectory)
    let result = try ExportService.export(
      workspace: workspace, to: root, store: environment.db, home: environment.home.url)
    return CommandOutput(
      text: "Exported \(result.workspace) to \(result.path) (\(result.files) files).", data: result
    ).reporting(workspace)
  }
}
