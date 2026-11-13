/// A bounded, masked rendering of one stored document revision.
package struct DocReadResult: Encodable, Sendable {
  /// The selected doc or immutable revision reference.
  package let ref: String
  /// Rendered metadata and content, with complete continuations when clipped.
  package let output: String
}

extension DocReadResult {
  init(masking ref: String, output: String) {
    self.ref = SecretGuard.redacted(ref)
    self.output = SecretGuard.redacted(output)
  }
}
