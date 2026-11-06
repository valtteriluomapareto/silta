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
      + "not written; configured values are written as stored. It stages in a hidden "
      + ".<workspace>.export-XXXXXX next to the tree; one it can't remove, or a crash left, is "
      + "an export_leftover warning for the human. Unreadable entries refuse the target.")

  static let dataShape = Shape.object([
    "workspace": .string, "path": .string, "files": .int, "sha": .optional(.string),
  ])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Option(
    help: ArgumentHelp(
      "The export root; the tree goes to <root>/<workspace>. Defaults to $SILTA_HOME/exports.",
      valueName: "root"))
  var to: String?

  @Flag(
    help: ArgumentHelp(
      "Commit only the workspace subtree in an existing Git work tree. "
        + "Ignored files produce warnings; an unchanged tree makes no commit.")
  )
  var commit = false

  /// Preserves output-affecting options when a lock refusal asks for a retry.
  var retryCommand: String {
    let command =
      "silta export" + (to.map { " --to " + shellWord($0) } ?? "")
      + (commit ? " --commit" : "")
    return global.ws.map { workspaceCommand(command, workspace: $0) } ?? command
  }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
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
    let result: ExportResult
    if commit {
      result = try await ExportService.commit(
        workspace: workspace, to: root, store: environment.db,
        home: environment.home.url, seams: (environment.git, environment.clock))
    } else {
      result = try ExportService.export(
        workspace: workspace, to: root, store: environment.db, home: environment.home.url,
        clock: environment.clock)
    }
    let warnings = result.leftovers.map(\.warning) + result.gitWarnings
    let receipt =
      commit ? result.sha.map { " Committed \($0)." } ?? " No staged changes; no commit." : ""
    return CommandOutput(
      text: "Exported \(result.workspace) to \(result.path) (\(result.files) files)." + receipt,
      data: result,
      warnings: warnings
    ).reporting(workspace)
  }
}
