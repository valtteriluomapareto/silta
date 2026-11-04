/// The stable code-read data shape and its accompanying fetch warnings.
package struct CodeResult: Encodable, Sendable {
  /// Selected workspace app.
  package let app: String
  /// Configured, production or explicitly selected ref.
  package let ref: String
  /// Immutable commit used for every read.
  package let sha: String
  /// UTF-8 output with command-specific stable formatting.
  package let output: String
  /// Warnings carried separately in the output envelope.
  package let warnings: [OutputWarning]

  private enum CodingKeys: String, CodingKey { case app, ref, sha, output }
}
