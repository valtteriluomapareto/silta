/// A bounded, masked rendering of one stored document revision.
package struct DocReadResult: Encodable, Sendable {
  /// The selected doc or immutable revision reference.
  package let ref: String
  /// Rendered metadata and content, with complete continuations when clipped.
  package let output: String
  /// The visible masked Markdown, preserving the stored source ending.
  package var body: String?
  /// Complete known metadata fields visible in the selected window.
  package var title: String?
  package var about: [String]?
  package var state: String?
  /// Typed viewer projection; omitted from the CLI JSON contract.
  package var metadata: DocDisplayMetadata?
  package var rendered: String?
  package var nextLine: Int?
  package var lines: DocLineWindow?
  var bodyLayout: DocBodyLayout?

  private enum CodingKeys: String, CodingKey {
    case ref, output, body, title, about, state
  }
}

extension DocReadResult {
  init(masking ref: String, output: String) {
    self.ref = SecretGuard.redacted(ref)
    self.output = SecretGuard.redacted(output)
  }
}

/// Line numbers in the masked body, independently of CLI metadata and continuation text.
package struct DocLineWindow: Sendable {
  package let first: Int
  package let last: Int
  package let total: Int
}
