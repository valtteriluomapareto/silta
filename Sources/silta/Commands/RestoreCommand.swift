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
      + "Run --dry-run first and show the human what it reports.")

  static let dataShape = Shape.object([
    "workspace": .string, "dry_run": .bool, "created": .bool, "same_uid": .bool,
    "manifest_sha256": .string, "tasks": .object(["before": .int, "after": .int]),
    "removed": .array(.string), "changed": .array(.string),
    "settings": .array(
      .object(["key": .string, "before": .optional(.string), "after": .optional(.string)])),
    "approvals_added": .int,
    "claims_replaced": .array(.object(["task": .string, "actor": .string])),
    "repos_without_path": .array(.string), "snapshot": .optional(.string),
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The export tree: <root>/<workspace>, holding manifest.json.")
  var dir: String

  @Flag(help: "Check and report the restore, then roll it back.")
  var dryRun = false

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
        command: "silta restore " + shellWord(directory.path), approved: global.approved)
    let report = try RestoreService.restore(
      RestoreRequest(
        directory: directory, workspace: global.ws, manifest: nil, approval: approval,
        dryRun: dryRun),
      store: environment.db, home: environment.home.url,
      identity: (environment.ids, environment.clock.now()))
    return CommandOutput(
      text: Self.text(report, directory: directory.path), data: report,
      approvalUsed: approval != nil
    ).reporting(report.workspace)
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
    if !report.settings.isEmpty {
      lines.append(
        "Settings: "
          + report.settings.map { "\($0.key) \($0.before ?? "unset") -> \($0.after ?? "unset")" }
          .joined(separator: "; ") + ".")
    }
    if report.approvalsAdded > 0 { lines.append("Approvals added: \(report.approvalsAdded).") }
    refs("Claims replaced", report.claimsReplaced.map { "\($0.task) (\($0.actor))" })
    if let snapshot = report.snapshot { lines.append("Before-restore snapshot: \(snapshot).") }
    if !report.reposWithoutPath.isEmpty {
      lines.append(
        "Repos without a local path: \(report.reposWithoutPath.joined(separator: ", ")); run "
          + workspaceCommand("silta init --scan <clone dir>…", workspace: report.workspace) + ".")
    }
    if dry { lines.append("Dry run: nothing was written.") }
    return lines.joined(separator: "\n")
  }
}
