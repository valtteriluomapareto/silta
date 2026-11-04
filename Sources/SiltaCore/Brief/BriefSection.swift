/// One budgeted block of brief text, shared by text and JSON output.
package struct BriefSection: Encodable, Equatable, Sendable {
  enum TrimPolicy: Equatable, Sendable {
    case atomic, characters
    case plan(ref: String, total: Int)
  }
  /// Stable section name.
  package let id: String
  /// Rendered content, including its heading and trailing newline.
  package var text: String
  var policy: TrimPolicy = .atomic

  enum CodingKeys: String, CodingKey { case id, text }
}
