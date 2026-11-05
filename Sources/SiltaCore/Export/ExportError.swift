/// Export failures. Each leaves the target as it was (spec §15), except `previousKept`,
/// which says where the previous tree is.
package enum ExportError: CodedError, Equatable {
  /// The target exists but is not exactly a previous export; `entry` is the first file
  /// that shows it.
  case notAnExport(path: String, entry: String, workspace: String)
  /// The export root lies inside a registered repo.
  case insideRepo(path: String, repo: String, workspace: String)
  /// The workspace holds data this binary can't export yet.
  case unsupported(String)
  /// The tree could not be written under the root.
  case unwritable(path: String, workspace: String)
  /// The new tree could not be put in place and the previous one could not be moved
  /// back; it is kept at `path`.
  case previousKept(path: String, target: String, workspace: String)
  /// A tree is not byte for byte what export writes.
  case invalidTree(String)

  /// Target and repo refusals leave the choice of directory to the human.
  package var code: ErrorCode {
    switch self {
    case .notAnExport: .conflict
    case .insideRepo, .invalidTree: .invalid
    case .unsupported, .unwritable, .previousKept: .env
    }
  }

  /// The human chooses another directory; nothing an agent changes in the call helps.
  package var nextBy: NextBy { .human }

  /// What was refused, with the path it concerns.
  package var message: String {
    switch self {
    case .notAnExport(let path, let entry, _):
      "\(path) is not a silta export: it holds \(entry). "
        + "Export replaces only a previous export, so it changed nothing."
    case .insideRepo(let path, let repo, _):
      "\(path) overlaps the registered repo \(repo); workspace data never goes into a code repo, "
        + "so export changed nothing."
    case .unsupported(let what):
      "This workspace has \(what), which this version of silta can't export; nothing was written."
    case .unwritable(let path, _):
      "The export could not be written under \(path); the previous export, if any, is unchanged."
    case .previousKept(let path, let target, _):
      "The new export could not replace \(target), and the previous export could not be "
        + "moved back; it is kept at \(path)."
    case .invalidTree(let reason):
      "Not an unchanged silta export tree: \(reason)."
    }
  }

  /// A directory the human picks, for the same workspace, or a newer binary.
  package var next: [String] {
    switch self {
    case .notAnExport(_, _, let workspace):
      [workspaceCommand("silta export --to <empty or export directory>", workspace: workspace)]
    case .insideRepo(_, _, let workspace):
      [
        workspaceCommand(
          "silta export --to <directory outside registered repos>", workspace: workspace)
      ]
    case .unwritable(_, let workspace):
      [workspaceCommand("silta export --to <writable directory>", workspace: workspace)]
    case .previousKept(let path, let target, _): ["mv " + shellWord(path) + " " + shellWord(target)]
    case .unsupported: ["update silta"]
    case .invalidTree: ["silta export"]
    }
  }
}
