/// Document input and identity failures, without stored body text.
enum DocError: CodedError {
  case missing([String])
  case invalid(String)
  case notFound(String)
  case changed(workspace: String)

  var code: ErrorCode {
    switch self {
    case .missing: .usage
    case .invalid: .invalid
    case .notFound: .notFound
    case .changed: .conflict
    }
  }

  var message: String {
    switch self {
    case .missing(let fields):
      "A doc with no accepted revision requires: " + fields.joined(separator: ", ") + "."
    case .invalid(let reason): reason
    case .notFound(let ref): "Doc " + TaskError.shown(ref) + " not found."
    case .changed: "Document metadata or app configuration changed; prepare the write again."
    }
  }

  var next: [String] {
    if case .changed(let workspace) = self {
      return [workspaceCommand("silta ws show", workspace: workspace)]
    }
    return ["silta ws show"]
  }
}
