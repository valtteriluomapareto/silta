import SiltaCore

/// What a command gets to run with. Seams join it as their slices land.
struct CommandContext: Sendable {
  /// How the result will be rendered. Commands must not shape their output by it:
  /// `OutputRouter` alone decides what goes where.
  var mode: OutputMode
}
