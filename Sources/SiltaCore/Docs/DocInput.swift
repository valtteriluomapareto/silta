/// Limits supplied document bodies, including after redaction.
package enum DocInput {
  /// The fixed supplied-input byte limit, before and after redaction.
  package static let maximumBytes = 64 * 1024

  static func check(_ text: String) throws {
    guard text.utf8.count <= maximumBytes else {
      throw DocError.invalid("Doc input exceeds 65536 bytes.")
    }
    guard !text.utf8.contains(0) else {
      throw DocError.invalid("Doc input must not contain NUL bytes.")
    }
  }
}
