/// Document input and identity failures, without stored body text.
enum DocError: CodedError {
  case missing([String])
  case invalid(String)
  case notFound(String)
  case stale(String)
  case duplicate(String)
  case overlap([String])
  case changed(workspace: String)

  var code: ErrorCode {
    switch self {
    case .missing: .usage
    case .invalid: .invalid
    case .notFound: .notFound
    case .stale: .staleRev
    case .duplicate, .overlap, .changed: .conflict
    }
  }

  var message: String {
    switch self {
    case .missing(let fields):
      "Missing required doc fields: " + fields.joined(separator: ", ") + "."
    case .invalid(let reason): reason
    case .notFound(let ref): "Doc " + TaskError.shown(ref) + " not found."
    case .stale(let ref):
      "Proposal " + TaskError.shown(ref) + " has a stale base; inspect and repropose."
    case .duplicate(let ref):
      "Document body and metadata already match " + TaskError.shown(ref) + "."
    case .overlap(let refs):
      "Accept at most one proposal per doc: " + refs.map(TaskError.shown).joined(separator: ", ")
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
