/// Configuration failures include every validation problem from one document.
package enum WorkspaceError: CodedError {
  /// The YAML document does not meet the workspace contract.
  case invalid([String])

  /// No matching workspace is available.
  case notFound

  /// Removing a configured row would break an existing reference.
  case conflict

  /// The editor could not be started.
  case editor

  /// The file cannot be read as UTF-8 YAML.
  case input

  /// Validation is a caller error; referenced deletions require reconciliation.
  package var code: ErrorCode {
    switch self {
    case .invalid: .invalid
    case .notFound: .notFound
    case .conflict: .conflict
    case .editor, .input: .env
    }
  }

  /// Explains the failure without exposing database diagnostics.
  package var message: String {
    switch self {
    case .invalid(let problems): problems.joined(separator: "; ")
    case .notFound: "No matching workspace is selected."
    case .conflict: "Configuration conflicts with an existing reference or unique value."
    case .editor: "The editor could not be started; check EDITOR."
    case .input: "Could not read UTF-8 workspace YAML; check the file path and permissions."
    }
  }

  /// Points to an available command for recovery.
  package var next: [String] {
    switch self {
    case .notFound: ["silta ws ls"]
    case .input: ["silta ws edit -F <file>"]
    default: ["silta ws edit"]
    }
  }
}
