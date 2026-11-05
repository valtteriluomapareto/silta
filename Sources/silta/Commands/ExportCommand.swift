import ArgumentParser
import Foundation
import SiltaCore

struct ExportCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Write one workspace as a deterministic text tree for backup and diff.",
    discussion:
      "The tree goes to <root>/<workspace>. It replaces only an absent, empty or previously "
      + "exported directory, never one inside a registered repo. Repo paths and worktrees are "
      + "not written; configured values are written as stored.")

  static let dataShape = Shape.object(["workspace": .string, "path": .string, "files": .int])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Option(
    help: ArgumentHelp(
      "The export root; the tree goes to <root>/<workspace>. Defaults to $SILTA_HOME/exports.",
      valueName: "root"))
  var to: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    if let to, to == "~" || to.hasPrefix("~/") {
      throw UsageError.invalid(
        message: "--to \(to) starts with an unexpanded ~; pass an absolute path",
        command: "silta export")
    }
    let workspace = try context.workspace(global.ws)
    let root =
      to.map { URL(filePath: $0, directoryHint: .isDirectory, relativeTo: .currentDirectory()) }
      ?? environment.home.url.appending(path: "exports", directoryHint: .isDirectory)
    let result = try ExportService.export(
      workspace: workspace, to: root, store: environment.db, home: environment.home.url)
    let warnings = result.leftovers.map {
      OutputWarning(
        code: "export_leftover",
        message:
          "\($0) is a work directory export did not remove; ask the human before deleting it.")
    }
    return CommandOutput(
      text: "Exported \(result.workspace) to \(result.path) (\(result.files) files).", data: result,
      warnings: warnings
    ).reporting(workspace)
  }
}
