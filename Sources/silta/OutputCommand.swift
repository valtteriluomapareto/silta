import ArgumentParser
import SiltaCore

/// A command that returns its result for `OutputRouter` to render, instead of
/// printing it. Every `silta` command conforms.
protocol OutputCommand: ParsableCommand {
  /// Runs the command. Throw a `CodedError` for anything the caller should act on.
  func execute(_ context: CommandContext) throws -> CommandOutput
}
