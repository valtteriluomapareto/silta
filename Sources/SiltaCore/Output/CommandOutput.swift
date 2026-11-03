/// A command's successful result, before rendering. Commands return this and never
/// write to stdout or stderr themselves (spec §20.1).
package struct CommandOutput: Sendable {
  /// The text-mode output.
  package var text: String
  /// The `data` of the JSON envelope.
  package var data: any Encodable & Sendable
  /// Warnings for either mode.
  package var warnings: [OutputWarning]

  /// Whether the command used a human-only gate; this is never serialized.
  package var approvalUsed: Bool

  /// The storage slug of the workspace the command resolved and acted on, or created,
  /// for the command log (spec §19). Never a raw argument, and never serialized; a
  /// successful command that leaves it nil is logged without a workspace.
  package var workspace: String?

  /// A result with text, envelope data and warnings.
  package init(
    text: String, data: any Encodable & Sendable, warnings: [OutputWarning] = [],
    approvalUsed: Bool = false
  ) {
    self.text = text
    self.data = data
    self.warnings = warnings
    self.approvalUsed = approvalUsed
  }
}
