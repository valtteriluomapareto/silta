/// Location failures with commands an agent can act on.
package enum LocationError: CodedError {
  case unregistered
  case invalidPath
  case git
  case app(String, workspace: String)
  case outsideCandidates([String], workspace: String, path: String)
  case changed(workspace: String, path: String)

  /// Maps registration, selection, configuration and environment failures to the CLI table.
  package var code: ErrorCode {
    switch self {
    case .unregistered: .unregistered
    case .invalidPath: .invalid
    case .git: .env
    case .app: .notFound
    case .outsideCandidates: .ambiguousLocation
    case .changed: .conflict
    }
  }

  /// Explains what prevented resolution without exposing raw git stderr.
  package var message: String {
    switch self {
    case .unregistered: "This path is not in a registered repository."
    case .invalidPath: "Location needs an existing directory."
    case .git: "Could not read git metadata for location; check the local repository."
    case .app(let app, _): "App \(app.debugDescription) was not found in this workspace."
    case .outsideCandidates: "The selected app does not belong to this path's candidates."
    case .changed: "Location configuration changed; read the location again before setting it."
    }
  }

  /// Supplies actionable retries, preserving an explicit workspace and target path.
  package var next: [String] {
    switch self {
    case .unregistered: ["silta init --scan <directory>"]
    case .invalidPath: ["silta where --help"]
    case .git: ["silta doctor"]
    case .app(_, let workspace): ["silta --ws \(shellWord(workspace)) ws show"]
    case .outsideCandidates(let apps, let workspace, let path):
      apps.isEmpty
        ? ["silta --ws \(shellWord(workspace)) ws show"]
        : apps.map {
          "silta --ws \(shellWord(workspace)) where --path \(shellWord(path)) --app \(shellWord($0))"
        }
    case .changed(let workspace, let path):
      ["silta --ws \(shellWord(workspace)) where --path \(shellWord(path))"]
    }
  }
}
