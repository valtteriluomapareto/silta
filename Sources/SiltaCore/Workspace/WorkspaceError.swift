/// Configuration failures include every validation problem from one document.
package enum WorkspaceError: CodedError {
  /// The YAML document does not meet the workspace contract.
  case invalid([String])

  /// A stored value cannot be used for the requested workspace policy.
  case setting(String, key: String, value: String)

  /// No matching workspace is available.
  case notFound

  /// No workspace has the slug the caller named.
  case unknown(String)

  /// Removing a configured row would break an existing reference.
  case conflict

  /// The editor could not be started.
  case editor

  /// The file cannot be read as UTF-8 YAML.
  case input

  /// Validation is a caller error; referenced deletions require reconciliation.
  package var code: ErrorCode {
    switch self {
    case .invalid, .setting: .invalid
    case .notFound, .unknown: .notFound
    case .conflict: .conflict
    case .editor, .input: .env
    }
  }

  /// Explains the failure without exposing database diagnostics.
  package var message: String {
    switch self {
    case .invalid(let problems): problems.joined(separator: "; ")
    case .setting(let workspace, let key, let value):
      "Workspace \(TaskError.shown(workspace)) setting \(key) has invalid stored value \(Self.preview(value))."
    case .notFound: "No matching workspace is selected."
    case .unknown(let slug): "No workspace is named \(TaskError.shown(slug))."
    case .conflict: "Configuration conflicts with an existing reference or unique value."
    case .editor: "The editor could not be started; check EDITOR."
    case .input: "Could not read UTF-8 workspace YAML; check the file path and permissions."
    }
  }

  /// Points to an available command for recovery.
  package var next: [String] {
    switch self {
    case .setting(let workspace, _, _): ["silta --ws " + shellWord(workspace) + " ws show"]
    case .notFound, .unknown: ["silta ws ls"]
    case .input: ["silta ws edit -F <file>"]
    default: ["silta ws edit"]
    }
  }

  private static func preview(_ value: String) -> String {
    let safe = TaskError.shown(value)
    let prefix = String(String.UnicodeScalarView(safe.unicodeScalars.prefix(160)))
    return safe.unicodeScalars.count > 160 ? prefix + "…" : prefix
  }
}
