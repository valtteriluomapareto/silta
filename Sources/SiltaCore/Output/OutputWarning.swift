/// A warning attached to a result: shown on stderr in text mode, and in the
/// envelope's `warnings` with `--json`.
package struct OutputWarning: Codable, Equatable, Sendable {
  /// A stable snake_case code, e.g. `ref_stale`.
  package var code: String
  /// What the caller should know, on one line.
  package var message: String

  /// A warning with `code` and `message`.
  package init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}
