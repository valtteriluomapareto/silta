/// Repository operations fail without exposing raw git output or credentials.
package enum RepoError: CodedError, Equatable {
  /// Discovery could not read the requested directories or git metadata.
  case scan

  /// A selected repository does not exist in this workspace.
  case notFound

  /// A discovered clone needs a matching repo entry before its path can be registered.
  case configuration(workspace: String)

  /// A clone needs to be restored or registered before fetching.
  case localPath

  /// Git failed for this repository in this workspace.
  case fetch(repo: String, workspace: String)

  /// Missing selections are caller errors; local and git failures require human repair.
  package var code: ErrorCode {
    self == .notFound ? .notFound : .env
  }

  /// Explains the failed operation without retaining git stderr.
  package var message: String {
    switch self {
    case .scan: "Could not discover repositories; check the scan directories and git metadata."
    case .configuration:
      "A discovered repo is absent from the workspace; add it in ws edit, then rescan."
    case .notFound: "No matching repository; check the workspace and repository slug."
    case .localPath:
      "A local clone is missing or unregistered; restore it and bind its path with init --scan."
    case .fetch(let repo, _):
      "Could not fetch \(repo); check network access and noninteractive git credentials."
    }
  }

  /// Gives body-free recovery commands, preserving the failed fetch target.
  package var next: [String] {
    switch self {
    case .scan: ["silta init --help"]
    case .notFound: ["silta repo fetch --help"]
    case .configuration(let workspace): ["silta ws edit \(shellWord(workspace))"]
    case .localPath: ["silta init --help"]
    case .fetch(let repo, let workspace):
      ["silta --ws \(shellWord(workspace)) repo fetch \(shellWord(repo))"]
    }
  }
}
