import SiltaCore

/// Command-scoped dependencies and output mode.
struct CommandContext: Sendable {
  /// How the result will be rendered. Commands must not shape their output by it:
  /// `OutputRouter` alone decides what goes where.
  var mode: OutputMode
  /// The single environment assembled at the process boundary.
  let environment: SiltaEnvironment
}
