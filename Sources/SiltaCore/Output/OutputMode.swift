/// How a command's result is rendered: the global `--json` and `--quiet` flags.
package struct OutputMode: Equatable, Sendable {
  /// Render the JSON envelope on stdout instead of text.
  package var json: Bool
  /// Hide success text; warnings and errors still show.
  package var quiet: Bool

  /// A mode from the global flags.
  package init(json: Bool, quiet: Bool = false) {
    self.json = json
    self.quiet = quiet
  }
}
