import ArgumentParser
import Foundation
import SiltaCore

struct WsEditCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit", abstract: "Edit workspace YAML (human-only).",
    discussion: "Keep the baseline comment from ws show or a retained editor draft. "
      + "If stale, review a fresh ws show before reapplying your edits. "
      + "An unstamped file uses the configuration at command start.\n"
      + "Preview map changes and blockers without approval using --dry-run -F <file>.\n"
      + "Update Acme YAML (human): silta ws edit acme -F acme.yml")

  static let dataShape = Shape.object([
    "workspace": .optional(.string), "dry_run": .optional(.bool),
    "changes": .optional(
      .object([
        "added": .array(.string), "removed": .array(.string),
        "renamed": .array(
          .object([
            "kind": .string, "from": .string, "to": .string, "docs": .int, "tasks": .int,
            "edges": .int, "environments": .int,
          ])),
        "blockers": .array(.object(["item": .string, "references": .array(.string)])),
      ])),
  ])

  static let workspaceSource = WorkspaceSource.argument

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The workspace slug; defaults to repository location, then the saved default.")
  var workspace: String?

  var workspaceArgument: String? { workspace }

  @Option(
    name: .customShort("F"), help: "Read UTF-8 YAML from a file, or - for stdin; default is none.")
  var file: String?

  @Flag(help: "Preview map changes and blockers without saving. Requires -F.")
  var dryRun = false

  func validate() throws {
    if dryRun, file == nil { throw ValidationError("--dry-run requires -F <file> or -F -.") }
    if file == nil { try TerminalEditor.validate() }
  }

  func authorize(_ context: CommandContext) throws {
    if dryRun { return }
    let target = (workspace ?? global.ws).map { " " + shellWord($0) } ?? ""
    let input = file == "-" ? " -F -" : " -F <file>"
    try context.environment.actor.requireHuman(
      command: "silta ws edit" + target + input, approved: global.approved)
  }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let environment = context.environment
    let workspace = workspace ?? global.ws
    if dryRun, let file {
      let preview = try WorkspaceEditor.preview(
        try BodyInput.read(file), slug: workspace, store: environment.db,
        prepared: environment.workspaceSelection)
      return receipt(preview).reporting(preview.workspace)
    }
    let identity = (environment.ids, environment.clock.now())
    let selected: WorkspaceEditResult?
    if let file {
      selected = try WorkspaceEditor.apply(
        try BodyInput.read(file), slug: workspace, store: environment.db, actor: environment.actor,
        identity: identity, approved: global.approved, prepared: environment.workspaceSelection,
        retryFromStdin: file == "-")
    } else {
      selected = try WorkspaceEditor.edit(
        slug: workspace, store: environment.db, actor: environment.actor,
        identity: identity, approved: global.approved, prepared: environment.workspaceSelection
      ) { file in
        try TerminalEditor.run(file, command: "silta ws edit")
      }
    }
    var output = receipt(selected)
    if let selected {
      output.warnings = await EdgeCodeEvidence.warnings(
        workspace: selected.workspace, environment: environment)
    }
    output.approvalUsed = selected != nil && !environment.actor.isHuman
    return output.reporting(selected?.workspace)
  }

  private func receipt(_ result: WorkspaceEditResult?) -> CommandOutput {
    let changes = result?.changes
    let workspace = result?.workspace
    var lines = [
      workspace.map { dryRun ? "Preview workspace \($0)." : "Updated workspace \($0)." }
        ?? "No changes."
    ]
    if let changes {
      if !changes.added.isEmpty {
        lines.append("Add: " + changes.added.map(HumanText.line).joined(separator: ", "))
      }
      if !changes.removed.isEmpty {
        lines.append("Remove: " + changes.removed.map(HumanText.line).joined(separator: ", "))
      }
      lines += changes.renamed.map { rename in
        "Rename \(rename.kind): \(HumanText.line(rename.from)) -> \(HumanText.line(rename.to)) "
          + "(docs \(rename.docs), tasks \(rename.tasks), edges \(rename.edges), environments \(rename.environments))"
      }
      lines += changes.blockers.map { blocker in
        "Blocked \(HumanText.line(blocker.item)): "
          + blocker.references.map(HumanText.line).joined(separator: ", ")
      }
      if dryRun && changes.isEmpty { lines.append("No map changes.") }
    }
    return CommandOutput(
      text: lines.joined(separator: "\n"),
      data: WsEditData(
        workspace: workspace, dryRun: dryRun ? true : nil,
        changes: dryRun || changes?.isEmpty == false ? changes : nil))
  }

}

private struct WsEditData: Encodable {
  let workspace: String?
  let dryRun: Bool?
  let changes: WorkspaceMapChanges?

  enum CodingKeys: String, CodingKey {
    case workspace, changes
    case dryRun = "dry_run"
  }
}
