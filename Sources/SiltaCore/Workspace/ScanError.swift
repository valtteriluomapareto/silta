import Foundation

/// The names a scan was asked to use, so a refusal can repeat them in its `next`.
package struct ScanChoice: Equatable, Sendable {
  package let slug: String?

  package let prefix: String?

  package init(slug: String? = nil, prefix: String? = nil) {
    self.slug = slug
    self.prefix = prefix
  }

  package init(_ target: ScanTarget) {
    if case .named(let slug, let prefix) = target {
      self.init(slug: slug, prefix: prefix)
    } else {
      self.init()
    }
  }

  package static let none = ScanChoice()

  /// The chosen slug, when it is a usable identifier.
  var usableSlug: String? {
    slug.flatMap { WorkspaceConfig.isValidIdentifier($0) ? $0 : nil }
  }

  /// The chosen prefix, when it is a usable identifier.
  var usablePrefix: String? {
    prefix.flatMap { WorkspaceConfig.isValidIdentifier($0) ? $0 : nil }
  }
}

/// Where a derived task prefix came from.
package enum PrefixOrigin: Equatable, Sendable {
  case directory(String)
  case slug(String)
}

/// What fixes a clone directory renamed by a scan refusal.
package enum ScanFollowUp: Equatable, Sendable {
  /// Rescan the renamed path into this existing workspace.
  case rescan(String)

  /// Create a workspace from the renamed path with these chosen names.
  case create(ScanChoice)
}

/// A scan cannot name the workspace it would create, or cannot bind a clone's path.
package enum ScanError: CodedError, Equatable {
  /// A chosen or directory-derived workspace slug is not an identifier.
  case invalidSlug(String, derived: Bool, directory: String, roots: [String], choice: ScanChoice)

  /// A task prefix is not an identifier. `origin` is nil when `--prefix` named the
  /// value, and names the slug or directory a derived value came from.
  case invalidPrefix(String, origin: PrefixOrigin?, roots: [String], choice: ScanChoice)

  /// A clone's directory name is not a valid repo slug, and no option renames it.
  /// `followUp` is set only when the renamed clone was the scan root itself.
  case invalidRepoDirectory(name: String, path: String, renamed: String, followUp: ScanFollowUp?)

  /// The slug the scan would create already names a workspace. `chosen` says
  /// whether `--slug` named it or the directory did and only `--prefix` was given.
  case slugExists(String, chosen: Bool, workspace: String, roots: [String], choice: ScanChoice)

  /// Another workspace already uses the task prefix.
  case prefixTaken(String, derived: Bool, workspace: String, roots: [String], choice: ScanChoice)

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
    case .invalidSlug(let value, let derived, let directory, _, _):
      return derived
        ? "Directory name \(directory.debugDescription) is not a valid workspace slug; use "
          + "letters, digits, _ or -, starting and ending with a letter or digit, or choose one "
          + "with --slug."
        : "Invalid workspace slug \(value.debugDescription); use letters, digits, _ or -, "
          + "starting and ending with a letter or digit."
    case .invalidPrefix(let value, let origin, _, _):
      let shape = "letters, digits, _ or -, starting and ending with a letter or digit"
      switch origin {
      case .directory(let name):
        return "Directory name \(name.debugDescription) gives the invalid task prefix "
          + "\(value.debugDescription); use \(shape), or choose one with --prefix."
      case .slug(let slug):
        return "Slug \(slug.debugDescription) gives the invalid task prefix "
          + "\(value.debugDescription); use \(shape), or choose one with --prefix."
      case nil:
        return "Invalid task prefix \(value.debugDescription); use \(shape)."
      }
    case .invalidRepoDirectory(let name, _, let renamed, _):
      return "Repo directory \(name.debugDescription) is not a valid repo slug; rename the clone's "
        + "directory to use letters, digits, _ or -, starting and ending with a letter or digit "
        + "(for example \(URL(filePath: renamed).lastPathComponent.debugDescription))."
    case .slugExists(_, let chosen, let workspace, _, _):
      return chosen
        ? "Workspace \(workspace.debugDescription) already exists; choose another --slug, or "
          + "rescan it to refresh only the repos already registered there."
        : "Workspace \(workspace.debugDescription) already exists; --prefix applies only to a "
          + "new workspace, so rescan it to refresh the repos already registered there, or pass "
          + "--slug to choose another name."
    case .prefixTaken(let prefix, let derived, let workspace, _, _):
      return derived
        ? "Task prefix \(prefix.debugDescription) is already used by workspace "
          + "\(workspace.debugDescription); it was derived from the workspace name, so pass "
          + "--prefix."
        : "Task prefix \(prefix.debugDescription) is already used by workspace "
          + "\(workspace.debugDescription); pass a different --prefix."
    case .repoPathTaken(let repo, _, let workspace):
      return "Repo \(repo.debugDescription) is already registered to workspace "
        + "\(workspace.debugDescription); scan a clone that belongs to this workspace, or rescan "
        + "the one that holds it."
    }
  }

  /// Every command repeats the naming options already given, so it lands on the
  /// same workspace the caller asked for, and carries the roots as typed.
  package var next: [String] {
    switch self {
    case .invalidSlug(_, _, _, let roots, let choice):
      return [command(roots: roots, slug: "<slug>", prefix: choice.usablePrefix)]
    case .invalidPrefix(_, _, let roots, let choice):
      return [command(roots: roots, slug: choice.usableSlug, prefix: "<prefix>")]
    case .invalidRepoDirectory(_, let path, let renamed, let followUp):
      return ["mv \(shellWord(path)) \(shellWord(renamed))"]
        + (followUp.map { [command($0, renamed: renamed)] } ?? [])
    case .slugExists(_, let chosen, let workspace, let roots, let choice):
      let another = command(roots: roots, slug: "<another-slug>", prefix: choice.usablePrefix)
      let rescan = "silta init --scan \(roots.scanArguments) --ws \(shellWord(workspace))"
      return chosen ? [another, rescan] : [rescan, another]
    case .prefixTaken(_, _, _, let roots, let choice):
      return [command(roots: roots, slug: choice.usableSlug, prefix: "<prefix>")]
    case .repoPathTaken(_, let path, let workspace):
      return ["silta --ws \(shellWord(workspace)) init --scan \(shellWord(path))"]
    }
  }

  private func command(_ followUp: ScanFollowUp, renamed: String) -> String {
    switch followUp {
    case .rescan(let workspace):
      "silta init --scan \(shellWord(renamed)) --ws \(shellWord(workspace))"
    case .create(let choice):
      command(roots: [renamed], slug: choice.usableSlug, prefix: choice.usablePrefix)
    }
  }

  private func command(roots: [String], slug: String?, prefix: String?) -> String {
    var words = ["silta init --scan \(roots.scanArguments)"]
    if let slug { words.append("--slug \(slug)") }
    if let prefix { words.append("--prefix \(prefix)") }
    return words.joined(separator: " ")
  }
}

extension [String] {
  /// The scan roots as one shell-quoted argument list.
  fileprivate var scanArguments: String {
    map(shellWord).joined(separator: " ")
  }
}
