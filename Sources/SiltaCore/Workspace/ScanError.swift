package import Foundation

/// A scan cannot name the workspace it would create, or cannot bind a clone's path.
package enum ScanError: CodedError, Equatable {
  /// A chosen or directory-derived workspace slug is not an identifier.
  case invalidSlug(String, derived: Bool, directory: String, roots: [String])

  /// A chosen or directory-derived task prefix is not an identifier.
  case invalidPrefix(String, derived: Bool, directory: String, roots: [String])

  /// A clone's directory name is not a valid repo slug, and no option renames it.
  case invalidRepoDirectory(name: String, path: String, renamed: String)

  /// The slug the scan would create already names a workspace.
  case slugExists(String, workspace: String, roots: [String])

  /// Another workspace already uses the task prefix.
  case prefixTaken(String, derived: Bool, workspace: String, roots: [String])

  /// Another workspace already binds the clone's path.
  case repoPathTaken(repo: String, path: String, workspace: String)

  package var code: ErrorCode {
    switch self {
    case .invalidSlug, .invalidPrefix, .invalidRepoDirectory: .invalid
    case .slugExists, .prefixTaken, .repoPathTaken: .conflict
    }
  }

  /// Renaming a clone's directory is the human's job, not the agent's.
  package var nextBy: NextBy {
    if case .invalidRepoDirectory = self { return .human }
    return code.nextBy
  }

  package var message: String {
    switch self {
    case .invalidSlug(let value, let derived, let directory, _):
      derived
        ? "Directory name \(directory.debugDescription) is not a valid workspace slug; use "
          + "letters, digits, _ or -, starting and ending with a letter or digit, or choose one "
          + "with --slug."
        : "Invalid workspace slug \(value.debugDescription); use letters, digits, _ or -, "
          + "starting and ending with a letter or digit."
    case .invalidPrefix(let value, let derived, let directory, _):
      derived
        ? "Directory name \(directory.debugDescription) gives the invalid task prefix "
          + "\(value.debugDescription); use letters, digits, _ or -, starting and ending with a "
          + "letter or digit, or choose one with --prefix."
        : "Invalid task prefix \(value.debugDescription); use letters, digits, _ or -, starting "
          + "and ending with a letter or digit."
    case .invalidRepoDirectory(let name, _, let renamed):
      "Repo directory \(name.debugDescription) is not a valid repo slug; rename the clone's "
        + "directory to use letters, digits, _ or -, starting and ending with a letter or digit "
        + "(for example \(URL(filePath: renamed).lastPathComponent.debugDescription))."
    case .slugExists(_, let workspace, _):
      "Workspace \(workspace.debugDescription) already exists; choose another --slug, or rescan "
        + "it to refresh only the repos already registered there."
    case .prefixTaken(let prefix, let derived, let workspace, _):
      derived
        ? "Task prefix \(prefix.debugDescription) is already used by workspace "
          + "\(workspace.debugDescription); it was derived from the workspace name, so pass "
          + "--prefix."
        : "Task prefix \(prefix.debugDescription) is already used by workspace "
          + "\(workspace.debugDescription); pass a different --prefix."
    case .repoPathTaken(let repo, _, let workspace):
      "Repo \(repo.debugDescription) is already registered to workspace "
        + "\(workspace.debugDescription); scan a clone that belongs to this workspace, or rescan "
        + "the one that holds it."
    }
  }

  /// Every command carries the scan's roots as typed, so it can be run unchanged.
  package var next: [String] {
    switch self {
    case .invalidSlug(_, _, _, let roots):
      ["silta init --scan \(roots.scanArguments) --slug <slug>"]
    case .invalidPrefix(_, _, _, let roots):
      ["silta init --scan \(roots.scanArguments) --prefix <prefix>"]
    case .invalidRepoDirectory(_, let path, let renamed):
      ["mv \(shellWord(path)) \(shellWord(renamed))"]
    case .slugExists(_, let workspace, let roots):
      [
        "silta init --scan \(roots.scanArguments) --slug <another-slug>",
        "silta init --scan \(roots.scanArguments) --ws \(shellWord(workspace))",
      ]
    case .prefixTaken(_, _, _, let roots):
      ["silta init --scan \(roots.scanArguments) --prefix <prefix>"]
    case .repoPathTaken(_, let path, let workspace):
      ["silta --ws \(shellWord(workspace)) init --scan \(shellWord(path))"]
    }
  }
}

extension [String] {
  /// The scan roots as one shell-quoted argument list.
  fileprivate var scanArguments: String {
    map(shellWord).joined(separator: " ")
  }
}
