/// Export and restore failures (spec §15). Publication and Git failures explicitly
/// distinguish a written tree or retained recovery data from pre-write refusals.
package enum ExportError: CodedError, Equatable {
  /// Another export held the lock through the bounded wait.
  case busy
  /// The target exists but is not exactly a previous export; `entry` says why, e.g.
  /// "it holds README.md".
  case notAnExport(path: String, entry: String, workspace: String)
  /// The export root lies inside a registered repo.
  case insideRepo(path: String, repo: String, workspace: String)
  /// The workspace holds data this binary can't export yet.
  case unsupported(String)
  /// The tree uses a canonical format version newer than this reader supports.
  case newerFormat
  /// The tree could not be written under the root.
  case unwritable(path: String, workspace: String)
  /// The new tree could not be put in place and the previous one could not be moved
  /// back; it is kept at `path`.
  case previousKept(path: String, target: String, workspace: String)
  /// A tree is not byte for byte what export writes, or doesn't hold together;
  /// `workspace` is the tree's, when its manifest names one.
  case invalidTree(reason: String, workspace: String?)
  /// The restore input is not an export tree; `child` is one inside it that is.
  case notATree(path: String, reason: String, child: String?)
  /// The tree's workspace is not the one `--ws` named.
  case otherWorkspace(tree: String, given: String, directory: String)
  /// The tree clashes with another workspace in this database.
  case restoreConflict(String)
  /// The tree's manifest is not the one the human approved.
  case manifestChanged(approved: String, directory: String)
  /// Git preflight refused before the export write.
  case notWorkTree(root: String)
  /// Git failed after publication; rerunning the export refreshes its owned paths.
  case gitFailed(root: String, workspace: String)
  /// The tree was published but the rename could not be flushed; recovery data stays.
  case publicationUnconfirmed(path: String, kept: String)

  /// Target and repo refusals leave the choice of directory to the human.
  package var code: ErrorCode {
    switch self {
    case .busy: .busy
    case .notAnExport, .restoreConflict, .manifestChanged: .conflict
    case .insideRepo, .invalidTree, .notATree, .otherWorkspace, .notWorkTree: .invalid
    case .unsupported, .newerFormat, .unwritable, .previousKept, .gitFailed,
      .publicationUnconfirmed:
      .env
    }
  }

  /// The human chooses another directory or tree; a dry run the agent may run itself
  /// is the agent's.
  package var nextBy: NextBy {
    switch self {
    case .notATree(_, _, .some), .otherWorkspace, .manifestChanged, .notWorkTree, .busy: .agent
    default: .human
    }
  }

  /// Retry spacing after export lock contention.
  package var retryAfter: Int? { self == .busy ? 5 : nil }

  /// What was refused, with the path it concerns.
  package var message: String {
    switch self {
    case .busy:
      "Another export holds the export lock; retry the same invocation once after retry_after_s."
    case .notWorkTree(let root):
      "\(root) is not an existing Git work tree; nothing was exported."
    case .gitFailed:
      "The export tree was written, but Git did not complete. It is safe to retry the same export; "
        + "check the repository's identity, permissions and hooks."
    case .publicationUnconfirmed(let path, let kept):
      "The export tree was written to \(path), but publication could not be flushed to disk. "
        + "The work directory is retained at \(kept); ask the human to inspect it before deleting anything."
    case .notAnExport(let path, let entry, _):
      "\(path) is not a silta export: \(entry). "
        + "Export replaces only a previous export, so it changed nothing."
    case .insideRepo(let path, let repo, _):
      "\(path) overlaps the registered repo \(repo); workspace data never goes into a code repo, "
        + "so export changed nothing."
    case .unsupported(let what):
      "This workspace has \(what), which this version of silta can't export; nothing was written."
    case .newerFormat:
      "This export uses a newer format than this version of silta can read; nothing was changed."
    case .unwritable(let path, _):
      "The export could not be written under \(path); the previous export, if any, is unchanged."
    case .previousKept(let path, let target, _):
      "The new export could not replace \(target), and the previous export could not be "
        + "moved back; it is kept at \(path), next to the new tree. Move it back only while "
        + "\(target) is absent; if another export has put a tree there since, keep that one."
    case .invalidTree(let reason, _):
      "Not an unchanged silta export tree: \(reason). Nothing was restored."
    case .notATree(let path, let reason, _):
      "\(path) is not an export tree: \(reason)."
    case .otherWorkspace(let tree, let given, _):
      "The tree holds workspace \(tree), not \(given); nothing was restored."
    case .restoreConflict(let reason):
      "The tree clashes with this database: \(reason). Nothing was restored."
    case .manifestChanged(let approved, _):
      "The tree is not the one approved (manifest \(approved)); it changed since the dry run. "
        + "Nothing was restored."
    }
  }

  /// A directory the human picks, for the same workspace, or a newer binary.
  package var next: [String] {
    switch self {
    case .busy: ["silta export"]
    case .notWorkTree(let root):
      [
        "git -C " + shellWord(root) + " rev-parse --is-inside-work-tree",
        "silta export --help",
      ]
    case .gitFailed(let root, let workspace):
      [workspaceCommand("silta export --to " + shellWord(root) + " --commit", workspace: workspace)]
    case .publicationUnconfirmed(_, let kept):
      ["/bin/ls -la " + shellWord(kept)]
    case .notAnExport(_, _, let workspace):
      [workspaceCommand("silta export --to <empty or export directory>", workspace: workspace)]
    case .insideRepo(_, _, let workspace):
      [
        workspaceCommand(
          "silta export --to <directory outside registered repos>", workspace: workspace)
      ]
    case .unwritable(_, let workspace):
      [workspaceCommand("silta export --to <writable directory>", workspace: workspace)]
    case .previousKept(let path, let target, _):
      ["[ ! -e \(shellWord(target)) ] && mv \(shellWord(path)) \(shellWord(target))"]
    case .unsupported, .newerFormat: ["update silta"]
    case .invalidTree(_, let workspace):
      [
        workspace.map {
          workspaceCommand(
            "silta export  # again, on the machine the tree came from", workspace: $0)
        } ?? "silta --ws <the tree's workspace> export"
          + "  # again, on the machine the tree came from"
      ]
    case .notATree(let path, _, let child):
      child.map { ["silta restore " + shellWord(path + "/" + $0) + " --dry-run"] }
        ?? [
          "silta --ws <the tree's workspace> export"
            + "  # on the source machine; restore its <root>/<workspace>"
        ]
    case .otherWorkspace(let tree, _, let directory):
      [workspaceCommand("silta restore " + shellWord(directory) + " --dry-run", workspace: tree)]
    case .restoreConflict: ["silta ws ls"]
    case .manifestChanged(_, let directory):
      ["silta restore " + shellWord(directory) + " --dry-run"]
    }
  }
}
