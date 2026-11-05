/// Export failures. Each leaves the target as it was (spec §15).
package enum ExportError: CodedError, Equatable {
  /// The target exists but is not exactly a previous export; `entry` is the first file
  /// that shows it.
  case notAnExport(path: String, entry: String)
  /// The export root lies inside a registered repo.
  case insideRepo(path: String, repo: String)
  /// The workspace holds data this binary can't export yet.
  case unsupported(String)
  /// The tree could not be written under the root.
  case unwritable(path: String)
  /// A tree is not byte for byte what export writes.
  case invalidTree(String)

  /// Target and repo refusals leave the choice of directory to the human.
  package var code: ErrorCode {
    switch self {
    case .notAnExport: .conflict
    case .insideRepo, .invalidTree: .invalid
    case .unsupported, .unwritable: .env
    }
  }

  /// The human chooses another directory; nothing an agent changes in the call helps.
  package var nextBy: NextBy { .human }

  /// What was refused, with the path it concerns.
  package var message: String {
    switch self {
    case .notAnExport(let path, let entry):
      "\(path) is not a silta export: it holds \(entry). "
        + "Export replaces only a previous export, so it changed nothing."
    case .insideRepo(let path, let repo):
      "\(path) is inside the registered repo \(repo); workspace data never goes into a code repo, "
        + "so export changed nothing."
    case .unsupported(let what):
      "This workspace has \(what), which this version of silta can't export; nothing was written."
    case .unwritable(let path):
      "The export could not be written under \(path); the previous export, if any, is unchanged."
    case .invalidTree(let reason):
      "Not an unchanged silta export tree: \(reason)."
    }
  }

  /// A directory the human picks, or a newer binary.
  package var next: [String] {
    switch self {
    case .notAnExport: ["silta export --to <empty or export directory>"]
    case .insideRepo: ["silta export --to <directory outside registered repos>"]
    case .unsupported: ["update silta"]
    case .unwritable: ["silta export --to <writable directory>"]
    case .invalidTree: ["silta export"]
    }
  }
}
