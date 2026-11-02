import SiltaCore

/// What a command gets to run with. Seams join it as their slices land.
struct CommandContext: Sendable {
  /// How the result will be rendered.
  var mode: OutputMode
}
