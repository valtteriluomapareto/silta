package import Foundation

/// The slug and task prefix a scan gives a new workspace.
package struct ScanNaming: Sendable, Equatable {
  package let slug: String

  package let prefix: String

  /// Uses the chosen values, or the first directory's lowercased name and its first
  /// two letters uppercased.
  package init(slug chosenSlug: String?, prefix chosenPrefix: String?, directory: URL) throws {
    let slug = chosenSlug ?? directory.standardizedFileURL.lastPathComponent.lowercased()
    guard WorkspaceConfig.isValidIdentifier(slug) else {
      throw ScanNamingError.invalidSlug(slug, derived: chosenSlug == nil)
    }
    let prefix = chosenPrefix ?? String(slug.prefix(2)).uppercased()
    guard WorkspaceConfig.isValidIdentifier(prefix) else {
      throw ScanNamingError.invalidPrefix(prefix, derived: chosenPrefix == nil)
    }
    self.slug = slug
    self.prefix = prefix
  }
}

/// A scan's chosen or derived workspace name cannot be used.
package enum ScanNamingError: CodedError, Equatable {
  case invalidSlug(String, derived: Bool)

  case invalidPrefix(String, derived: Bool)

  case slugExists(String)

  package var code: ErrorCode {
    switch self {
    case .invalidSlug, .invalidPrefix: .invalid
    case .slugExists: .conflict
    }
  }

  package var message: String {
    switch self {
    case .invalidSlug(let value, let derived):
      derived
        ? "Directory name \(value.debugDescription) is not a valid workspace slug; pass --slug."
        : "invalid slug \(value.debugDescription); choose one with --slug using letters, digits, "
          + "_ or - and starting and ending with a letter or digit."
    case .invalidPrefix(let value, let derived):
      derived
        ? "Directory name gives the invalid task prefix \(value.debugDescription); pass --prefix."
        : "invalid task_prefix \(value.debugDescription); choose one with --prefix using "
          + "letters, digits, _ or - and starting and ending with a letter or digit."
    case .slugExists(let slug):
      "Workspace \(TaskError.shown(slug)) already exists; rescan it with --ws instead of "
        + "choosing its name."
    }
  }

  package var next: [String] {
    switch self {
    case .invalidSlug, .invalidPrefix: ["silta init --help"]
    case .slugExists(let slug): ["silta init --scan <directory> --ws \(shellWord(slug))"]
    }
  }
}
