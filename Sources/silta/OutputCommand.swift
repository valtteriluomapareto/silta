import ArgumentParser
import SiltaCore

/// A command that returns its result for `OutputRouter` to render, instead of
/// printing it. Every `silta` command conforms.
protocol OutputCommand: ParsableCommand {
  /// Supplies explicit workspace context for recovery commands.
  var global: GlobalOptions { get }

  /// The shape of the `data` in this command's `--json` output, published by
  /// `silta schema`.
  static var dataShape: Shape { get }

  /// Where the command takes the workspace it acts on (spec §19). A successful command
  /// reports the workspace it resolved in `CommandOutput.workspace`; this attributes
  /// failures and usage errors.
  static var workspaceSource: WorkspaceSource { get }

  /// The app the command names with `--app`, if any.
  var appSlug: String? { get }

  /// Runs the command. Throw a `CodedError` for anything the caller should act on.
  func execute(_ context: CommandContext) async throws -> CommandOutput
}

extension OutputCommand {
  var appSlug: String? { nil }
}

/// A command whose workspace is its slug argument when given (`ws show|edit|use`).
protocol WorkspaceArgumentCommand: OutputCommand {
  /// The slug argument, if given.
  var workspaceArgument: String? { get }
}

/// Where a command takes the workspace it acts on.
enum WorkspaceSource {
  /// The command acts on no workspace.
  case none
  /// `--ws`, else the current workspace.
  case option
  /// The command's slug argument, else `--ws`, else the current workspace.
  case argument
}
