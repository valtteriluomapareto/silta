/// A command's successful result, before rendering. Commands return this and never
/// write to stdout or stderr themselves (spec §20.1).
package struct CommandOutput: Sendable {
  /// The text-mode output.
  package var text: String
  /// The `data` of the JSON envelope.
  package var data: any Encodable & Sendable
  /// Warnings for either mode.
  package var warnings: [OutputWarning]

  /// A result with text, envelope data and warnings.
  package init(text: String, data: any Encodable & Sendable, warnings: [OutputWarning] = []) {
    self.text = text
    self.data = data
    self.warnings = warnings
  }
}
