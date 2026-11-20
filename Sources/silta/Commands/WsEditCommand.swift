import ArgumentParser
import Foundation
import SiltaCore

struct WsEditCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit", abstract: "Edit workspace YAML (human-only).",
    discussion: "Keep the baseline comment from ws show or a retained editor draft. "
      + "If stale, review a fresh ws show before reapplying your edits. "
      + "An unstamped file uses the configuration at command start.\n"
      + "Update Acme YAML (human): silta ws edit acme -F acme.yml")

  static let dataShape = Shape.object(["workspace": .optional(.string)])

  static let workspaceSource = WorkspaceSource.argument

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The workspace slug; defaults to repository location, then the saved default.")
  var workspace: String?

  var workspaceArgument: String? { workspace }

  @Option(
    name: .customShort("F"), help: "Read UTF-8 YAML from a file, or - for stdin; default is none.")
  var file: String?

  func validate() throws {
    if file == nil { try TerminalEditor.validate() }
  }

  func authorize(_ context: CommandContext) throws {
    let target = (workspace ?? global.ws).map { " " + shellWord($0) } ?? ""
    let input = file == "-" ? " -F -" : " -F <file>"
    try context.environment.actor.requireHuman(
      command: "silta ws edit" + target + input, approved: global.approved)
  }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let environment = context.environment
    let workspace = workspace ?? global.ws
    let identity = (environment.ids, environment.clock.now())
    let selected: String?
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
    var output = CommandOutput(
      text: selected.map { "Updated workspace \($0)." } ?? "No changes.",
      data: Data(workspace: selected), approvalUsed: selected != nil && !environment.actor.isHuman)
    if let selected {
      output.warnings = await EdgeCodeEvidence.warnings(
        workspace: selected, environment: environment)
    }
    output.workspace = selected
    return output
  }

  private struct Data: Encodable {
    let workspace: String?
  }
}
