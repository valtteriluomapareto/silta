/// One budgeted block of brief text, shared by text and JSON output.
package struct BriefSection: Encodable, Equatable, Sendable {
  /// Stable section name.
  package let id: String
  /// Rendered content, including its heading and trailing newline.
  package var text: String
}
