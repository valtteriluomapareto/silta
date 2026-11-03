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

  /// Whether the command acts on a workspace, so its log line names it (spec §19).
  static var actsOnWorkspace: Bool { get }

  /// The slug the command resolves its workspace from; nil means the current workspace.
  var workspaceSlug: String? { get }

  /// The app the command names with `--app`, if any.
  var appSlug: String? { get }

  /// Runs the command. Throw a `CodedError` for anything the caller should act on.
  func execute(_ context: CommandContext) async throws -> CommandOutput
}

extension OutputCommand {
  var workspaceSlug: String? { global.ws }

  var appSlug: String? { nil }
}
