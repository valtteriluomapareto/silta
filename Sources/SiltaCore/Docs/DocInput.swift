/// Limits supplied document bodies, including after redaction.
enum DocInput {
  static func check(_ text: String) throws {
    guard text.utf8.count <= BoundedInput.maximumBodyBytes else {
      throw DocError.invalid("Doc input exceeds 65536 bytes.")
    }
    guard !text.utf8.contains(0) else {
      throw DocError.invalid("Doc input must not contain NUL bytes.")
    }
  }
}
