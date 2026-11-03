/// Repository operations fail without exposing raw git output or credentials.
package enum RepoError: CodedError, Equatable {
  /// Discovery could not read the requested directories or git metadata.
  case scan

  /// A selected repository does not exist in this workspace.
  case notFound

  /// A discovered clone needs a matching repo entry before its path can be registered.
  case configuration(repo: String, workspace: String)

  /// Discovered clones need distinct slugs before any path can be chosen.
  case duplicateSlug

  /// A clone needs to be restored or registered before fetching.
  case localPath(repo: String, workspace: String)

  /// Git failed for this repository in this workspace.
  case fetch(repo: String, workspace: String)

  /// Missing selections are caller errors; local and git failures require human repair.
  package var code: ErrorCode {
    switch self {
    case .notFound: .notFound
    case .duplicateSlug: .conflict
    default: .env
    }
  }

  /// Explains the failed operation without retaining git stderr.
  package var message: String {
    switch self {
    case .scan: "Could not discover repositories; check the scan directories and git metadata."
    case .configuration(let repo, _):
      "Discovered repo \(repo.debugDescription) is absent from the workspace; "
        + "add it in ws edit, then rescan."
    case .duplicateSlug:
      "More than one clone has the same repo slug; scan unambiguous directories."
    case .notFound: "No matching repository; check the workspace and repository slug."
    case .localPath(let repo, let workspace):
      "Local clone for \(repo) in \(workspace) is missing or unregistered; "
        + "restore it, then bind its path with init --scan."
    case .fetch(let repo, _):
      "Could not fetch \(repo); check network access and noninteractive git credentials. "
        + "Earlier successful repos remain fetched."
    }
  }

  /// Gives body-free recovery commands, preserving the failed fetch target.
  package var next: [String] {
    switch self {
    case .scan: ["silta init --help"]
    case .notFound: ["silta repo fetch --help"]
    case .configuration(_, let workspace): ["silta ws edit \(shellWord(workspace))"]
    case .duplicateSlug: ["silta init --help"]
    case .localPath(_, let workspace):
      ["silta --ws \(shellWord(workspace)) init --scan <directory>"]
    case .fetch(let repo, let workspace):
      ["silta --ws \(shellWord(workspace)) repo fetch \(shellWord(repo))"]
    }
  }
}
