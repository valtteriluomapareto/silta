/// An error that isn't a `CodedError` reached the output layer: a bug in Silta.
/// It is reported as `env` without echoing the arguments, which can carry bodies.
package struct InternalError: CodedError {
  /// The longest description kept, so a runaway message can't flood the output.
  static let maxDescription = 200

  /// The first line of the underlying error's description, capped.
  package let description: String

  /// Wraps `error`, keeping only the first line of its description.
  package init(_ error: any Error) {
    let firstLine = String(describing: error).split(separator: "\n").first ?? ""
    description = String(firstLine.prefix(Self.maxDescription))
  }

  package var code: ErrorCode { .env }
  package var message: String { "internal error (bug): \(description)" }
  package var next: [String] { ["silta doctor"] }
}
