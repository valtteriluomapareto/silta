/// A rejected write containing secret content; stores only masked previews.
package struct SecretError: CodedError {
  /// Caller-correctable secret refusal.
  package var code: ErrorCode {
    .invalid
  }
  /// Rules and bounded previews, without the original body.
  package let message: String
  /// Safe retry skeleton with the explicit override.
  package let next: [String]

  /// `command` is a fixed command skeleton, never original arguments or user text.
  /// Scans `text` but retains only masked previews; does not write or log anything.
  package init(command: StaticString, text: String) {
    let previews = SecretGuard.matches(in: text).map { $0.preview(in: text) }
    message = "Secret content detected: " + previews.joined(separator: ", ")
    next = [String(describing: command) + " --allow-secret"]
  }
}
