/// Export failures. Each leaves the target as it was (spec §15).
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
  /// A tree is not byte for byte what export writes, or doesn't hold together.
  case invalidTree(String)
  /// The restore input is not an export tree; `child` is one inside it that is.
  case notATree(path: String, reason: String, child: String?)
  /// The tree's workspace is not the one `--ws` named.
  case otherWorkspace(tree: String, given: String, directory: String)
  /// The tree clashes with another workspace in this database.
  case restoreConflict(String)

  /// Target and repo refusals leave the choice of directory to the human.
  package var code: ErrorCode {
    switch self {
    case .notAnExport, .restoreConflict: .conflict
    case .insideRepo, .invalidTree, .notATree, .otherWorkspace: .invalid
    case .unsupported, .unwritable: .env
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
    case .invalidTree(let reason):
      "Not an unchanged silta export tree: \(reason). Nothing was restored."
    case .notATree(let path, let reason, _):
      "\(path) is not an export tree: \(reason)."
    case .otherWorkspace(let tree, let given, _):
      "The tree holds workspace \(tree), not \(given); nothing was restored."
    case .restoreConflict(let reason):
      "The tree clashes with this database: \(reason). Nothing was restored."
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
    case .unsupported: ["update silta"]
    case .invalidTree: ["silta export  # again, on the machine the tree came from"]
    case .notATree(let path, _, let child):
      child.map { ["silta restore " + shellWord(path + "/" + $0) + " --dry-run"] }
        ?? ["silta export  # on the source machine; restore its <root>/<workspace>"]
    case .otherWorkspace(let tree, _, let directory):
      [workspaceCommand("silta restore " + shellWord(directory) + " --dry-run", workspace: tree)]
    case .restoreConflict: ["silta ws ls"]
    }
  }
}
