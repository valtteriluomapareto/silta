import Foundation

/// Configuration failures include every validation problem from one document.
package enum WorkspaceError: CodedError {
  /// The YAML document does not meet the workspace contract.
  case invalid([String])

  /// A safely rendered stored value cannot be used for the requested policy.
  case setting(String, key: String, value: String)

  /// An unknown policy word may belong to a newer writer; humans decide any change.
  case unknownSetting(String, key: String, value: String)

  /// No matching workspace is available.
  case notFound

  /// No workspace has the slug the caller named.
  case unknown(String)

  /// The repository has registrations in several workspaces and no selection overrides it.
  case ambiguous([String])

  /// Removing a configured row would break an existing reference.
  case conflict

  /// The editor could not be started.
  case editor

  /// The file cannot be read as UTF-8 YAML.
  case input

  /// Validation is a caller error; referenced deletions require reconciliation.
  package var code: ErrorCode {
    switch self {
    case .invalid, .setting, .unknownSetting: .invalid
    case .notFound, .unknown: .notFound
    case .ambiguous: .ambiguousLocation
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
    case .unknownSetting(let workspace, let key, let value):
      "Workspace \(TaskError.shown(workspace)) setting \(key) has unknown stored value \(Self.preview(value)); "
        + "it may come from a newer silta. Ask the human before choosing or changing the policy."
    case .notFound: "No matching workspace is selected."
    case .unknown(let slug): "No workspace is named \(TaskError.shown(slug))."
    case .ambiguous:
      "This repository belongs to several workspaces. "
        + "Retry the original command with --ws and a workspace from the candidates."
    case .conflict: "Configuration conflicts with an existing reference or unique value."
    case .editor: "The editor could not be started; check EDITOR."
    case .input: "Could not read UTF-8 workspace YAML; check the file path and permissions."
    }
  }

  /// Points to an available command for recovery.
  package var next: [String] {
    switch self {
    case .setting(let workspace, _, _), .unknownSetting(let workspace, _, _):
      ["silta --ws " + shellWord(workspace) + " ws show"]
    case .notFound, .unknown: ["silta ws ls"]
    case .ambiguous(let workspaces): workspaces.map { "silta --ws " + shellWord($0) + " ws show" }
    case .input: ["silta ws edit -F <file>"]
    default: ["silta ws edit"]
    }
  }

  private static func preview(_ value: String) -> String {
    let safe = value.unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) ? " " : String($0)
    }.joined()
    let prefix = String(String.UnicodeScalarView(safe.unicodeScalars.prefix(120)))
    return safe.unicodeScalars.count > 120 ? prefix + "…" : prefix
  }
}
