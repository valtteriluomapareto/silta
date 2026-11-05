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

  /// A supplied value a `next` must keep, rendered with its option. It stays bare when
  /// it is a valid identifier and is shell-quoted otherwise, so an unusable value
  /// reaches its own validation refusal instead of being dropped. A value starting
  /// with `-` joins its option with `=`, so the parser reads it as a value rather than
  /// another option.
  static func carried(_ value: String?, option: String) -> String? {
    value.map { value in
      guard !WorkspaceConfig.isValidIdentifier(value) else { return "\(option) \(value)" }
      return value.hasPrefix("-")
        ? "\(option)=\(shellWord(value))" : "\(option) \(shellWord(value))"
    }
  }

  /// The supplied `--slug`, if any, as a `next` keeps it.
  static func slug(_ choice: ScanChoice) -> String? {
    carried(choice.slug, option: "--slug")
  }

  /// The supplied `--prefix`, if any, as a `next` keeps it.
  static func prefix(_ choice: ScanChoice) -> String? {
    carried(choice.prefix, option: "--prefix")
  }
}

/// Where a derived task prefix came from.
package enum PrefixOrigin: Equatable, Sendable {
  case directory(String)
  case slug(String)
}

/// A scan cannot name the workspace it would create, or cannot bind a clone's path.
package enum ScanError: CodedError, Equatable {
  /// A chosen or directory-derived workspace slug is not an identifier.
  case invalidSlug(String, derived: Bool, directory: String, roots: [String], choice: ScanChoice)

  /// A task prefix is not an identifier. `origin` is nil when `--prefix` named the
  /// value, and names the slug or directory a derived value came from.
  case invalidPrefix(String, origin: PrefixOrigin?, roots: [String], choice: ScanChoice)

  /// The slug the scan would create already names a workspace. `chosen` says
  /// whether `--slug` named it or the directory did and only `--prefix` was given.
  case slugExists(String, chosen: Bool, workspace: String, roots: [String], choice: ScanChoice)

  /// Another workspace already uses the task prefix.
  case prefixTaken(String, derived: Bool, workspace: String, roots: [String], choice: ScanChoice)

  /// Another workspace already binds the clone's path.
  case repoPathTaken(repo: String, path: String, workspace: String)

  /// A clone's slug is `none`, the word that means non-code work.
  case reservedSlug(path: String)

  package var code: ErrorCode {
    switch self {
    case .invalidSlug, .invalidPrefix: .invalid
    case .slugExists, .prefixTaken, .repoPathTaken, .reservedSlug: .conflict
    }
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
    case .reservedSlug(let path):
      return "Clone at \(path.debugDescription) has the repo slug \(TaskDraft.noneApp), which "
        + "means non-code work in --app \(TaskDraft.noneApp); give the clone's directory a "
        + "different name and scan again."
    }
  }

  /// Every command repeats the naming options already given, so it lands on the
  /// same workspace the caller asked for, and carries the roots as typed.
  package var next: [String] {
    switch self {
    case .invalidSlug(_, _, _, let roots, let choice):
      return [command(roots: roots, "--slug <slug>", ScanChoice.prefix(choice))]
    case .invalidPrefix(_, _, let roots, let choice):
      return [command(roots: roots, ScanChoice.slug(choice), "--prefix <prefix>")]
    case .slugExists(_, let chosen, let workspace, let roots, let choice):
      let another = command(roots: roots, "--slug <another-slug>", ScanChoice.prefix(choice))
      let rescan = "silta init --scan \(roots.scanArguments) --ws \(shellWord(workspace))"
      return chosen ? [another, rescan] : [rescan, another]
    case .prefixTaken(_, _, _, let roots, let choice):
      return [command(roots: roots, ScanChoice.slug(choice), "--prefix <prefix>")]
    case .repoPathTaken(_, let path, let workspace):
      return ["silta --ws \(shellWord(workspace)) init --scan \(shellWord(path))"]
    case .reservedSlug: return ["silta init --help"]
    }
  }

  /// A scan command followed by the naming options the caller already gave.
  private func command(roots: [String], _ options: String?...) -> String {
    (["silta init --scan \(roots.scanArguments)"] + options.compactMap { $0 })
      .joined(separator: " ")
  }
}

extension [String] {
  /// The scan roots as one shell-quoted argument list.
  fileprivate var scanArguments: String {
    map(shellWord).joined(separator: " ")
  }
}
