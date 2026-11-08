import ArgumentParser
import Foundation
import SiltaCore

struct RestoreCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "restore",
    abstract: "Replace a workspace from an export tree (human-only, except --dry-run).",
    discussion:
      "<dir> is the <root>/<workspace> directory that holds manifest.json. The workspace's rows "
      + "are replaced in one transaction, approvals are kept, and nothing is written on failure. "
      + "Run --dry-run first and show the human what it reports.\n"
      + "Preview Acme restore: silta restore acme-exports/acme --dry-run\n"
      + "Restore manifest (human): silta restore acme-exports/acme --manifest SHA")

  static let dataShape = Shape.object([
    "workspace": .string, "dry_run": .bool, "created": .bool, "same_uid": .bool,
    "manifest_sha256": .string, "tasks": .object(["before": .int, "after": .int]),
    "removed": .array(.string), "changed": .array(.string),
    "settings": .array(
      .object(["key": .string, "before": .optional(.string), "after": .optional(.string)])),
    "next_task_ref": .object(["before": .optional(.string), "after": .optional(.string)]),
    "approvals_added": .int,
    "claims_replaced": .array(.object(["task": .string, "actor": .string])),
    "repos_without_path": .array(.string), "snapshot": .optional(.string),
    "rows": .array(.object(["table": .string, "before": .int, "after": .int])),
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The export tree: <root>/<workspace>, holding manifest.json.")
  var dir: String

  @Flag(help: "Check and report the restore, then roll it back.")
  var dryRun = false

  @Option(
    help: ArgumentHelp(
      "The manifest sha256 prefix the dry run printed; default is none. "
        + "A different tree is refused.",
      valueName: "sha"))
  var manifest: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    if dir == "~" || dir.hasPrefix("~/") {
      throw UsageError.invalid(
        message: "\(dir) starts with an unexpanded ~; pass an absolute path",
        command: "silta restore")
    }
    let directory = URL(filePath: dir, directoryHint: .isDirectory, relativeTo: .currentDirectory())
      .standardizedFileURL
    let approval =
      dryRun
      ? nil
      : try environment.actor.requireHuman(
        command: "silta restore " + shellWord(directory.path)
          + (manifest.map { " --manifest " + shellWord($0) } ?? ""), approved: global.approved)
    let report = try RestoreService.restore(
      RestoreRequest(
        directory: directory, workspace: global.ws, manifest: manifest, approval: approval,
        dryRun: dryRun),
      store: environment.db, home: environment.home.url,
      identity: (environment.ids, environment.clock.now()))
    return CommandOutput(
      text: Self.text(report, directory: directory.path), data: report,
      approvalUsed: approval != nil
    ).reporting(report.workspace)
  }

  /// The task ref the next task gets, when the restore moves it.
  static func counterLine(_ ref: RestoreReport.TaskRef) -> String? {
    guard ref.before != ref.after else { return nil }
    return "Next task ref: \(ref.before ?? "unset") -> \(ref.after ?? "unset")."
  }

  static func text(_ report: RestoreReport, directory: String) -> String {
    let dry = report.dryRun
    let verb = report.created ? "create" : "replace"
    var lines = [
      "\(dry ? "Would restore" : "Restored") \(report.workspace) from \(directory) "
        + "(manifest \(report.manifestSHA256.prefix(12))): "
        + "\(dry ? "would \(verb)" : "\(verb)d") the workspace.",
      "Tasks: \(report.tasks.before) -> \(report.tasks.after).",
    ]
    if !report.sameUID { lines.append("The replaced workspace has another uid than the tree's.") }
    func refs(_ label: String, _ list: [String]) {
      guard !list.isEmpty else { return }
      let shown = list.prefix(10).joined(separator: ", ")
      lines.append("\(label): \(shown)\(list.count > 10 ? ", and \(list.count - 10) more" : "").")
    }
    refs("Removed since the export", report.removed)
    refs("Changed since the export", report.changed)
    if !report.rows.isEmpty {
      lines.append(
        "Other rows: "
          + report.rows.map { "\($0.table) \($0.before) -> \($0.after)" }.joined(separator: ", ")
          + ".")
    }
    if !report.settings.isEmpty {
      lines.append(
        "Settings: "
          + report.settings.map { "\($0.key) \($0.before ?? "unset") -> \($0.after ?? "unset")" }
          .joined(separator: "; ") + ".")
    }
    if let ref = counterLine(report.nextTaskRef) { lines.append(ref) }
    if report.approvalsAdded > 0 { lines.append("Approvals added: \(report.approvalsAdded).") }
    refs("Claims replaced", report.claimsReplaced.map { "\($0.task) (\($0.actor))" })
    if let snapshot = report.snapshot {
      lines.append(
        "Before-restore snapshot: \(snapshot); to go back, open it as silta.db in an empty "
          + "SILTA_HOME, export \(report.workspace) there and restore that export.")
    }
    if !report.reposWithoutPath.isEmpty {
      lines.append(
        "Repos without a local path: \(report.reposWithoutPath.joined(separator: ", ")); run "
          + workspaceCommand("silta init --scan <clone dir>…", workspace: report.workspace) + ".")
    }
    if dry {
      lines.append("Dry run: the workspace was not changed.")
      lines.append(
        "ask human: silta restore " + shellWord(directory) + " --manifest "
          + report.manifestSHA256.prefix(12) + " --approved \"<the human's words>\"")
    }
    return lines.joined(separator: "\n")
  }
}
