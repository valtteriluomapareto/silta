/// Document input and identity failures, without stored body text.
enum DocError: CodedError {
  case missing([String])
  case invalid(String)
  case notFound(String)

  var code: ErrorCode {
    switch self {
    case .missing: .usage
    case .invalid: .invalid
    case .notFound: .notFound
    }
  }

  var message: String {
    switch self {
    case .missing(let fields):
      "A doc with no accepted revision requires: " + fields.joined(separator: ", ") + "."
    case .invalid(let reason): reason
    case .notFound(let ref): "Doc " + TaskError.shown(ref) + " not found."
    }
  }

  var next: [String] { ["silta ws show"] }
}
