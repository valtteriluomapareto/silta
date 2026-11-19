import ArgumentParser
import Foundation
import SiltaCore

struct WsEditCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit", abstract: "Edit workspace YAML (human-only).",
    discussion: "Update Acme YAML (human): silta ws edit acme -F acme.yml")

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

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    let workspace = workspace ?? global.ws
    let identity = (environment.ids, environment.clock.now())
    let selected: String?
    if let file {
      selected = try WorkspaceEditor.apply(
        try read(file), slug: workspace, store: environment.db, actor: environment.actor,
        identity: identity, approved: global.approved, prepared: environment.workspaceSelection)
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
    output.workspace = selected
    return output
  }

  private func read(_ file: String) throws -> String {
    do {
      let data =
        try file == "-"
        ? FileHandle.standardInput.readToEnd() ?? Foundation.Data()
        : Foundation.Data(contentsOf: URL(filePath: file))
      guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.input }
      return text
    } catch { throw WorkspaceError.input }
  }

  private struct Data: Encodable {
    let workspace: String?
  }
}
