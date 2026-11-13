/// One budgeted block of brief text, shared by text and JSON output.
package struct BriefSection: Encodable, Equatable, Sendable {
  enum TrimPolicy: Equatable, Sendable {
    case atomic, characters
    case excerpt(marker: String)
    case plan(ref: String, total: Int)
  }
  /// Stable section name.
  package let id: String
  /// Rendered content, including its heading and trailing newline.
  package var text: String
  var policy: TrimPolicy = .atomic

  var beforeTask = false
  var truncated = false
  var documents: [BriefDocGroup] = []

  enum CodingKeys: String, CodingKey { case id, text }
}
