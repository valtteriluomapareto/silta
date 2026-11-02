import ArgumentParser
import SiltaCore

/// A command that returns its result for `OutputRouter` to render, instead of
/// printing it. Every `silta` command conforms.
protocol OutputCommand: ParsableCommand {
  /// The shape of the `data` in this command's `--json` output, published by
  /// `silta schema`.
  static var dataShape: Shape { get }

  /// Runs the command. Throw a `CodedError` for anything the caller should act on.
  func execute(_ context: CommandContext) throws -> CommandOutput
}
