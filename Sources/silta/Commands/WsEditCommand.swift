import ArgumentParser
import Foundation
import SiltaCore

struct WsEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit", abstract: "Edit workspace YAML (human-only).")

  static let dataShape = Shape.object(["workspace": .optional(.string)])

  static let actsOnWorkspace = true

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The workspace slug; defaults to the current workspace.")
  var workspace: String?

  var workspaceSlug: String? { workspace ?? global.ws }

  @Option(name: .customShort("F"), help: "Read UTF-8 YAML from a file, or - for stdin.")
  var file: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    let selected: String?
    if let file {
      let target = (workspace ?? global.ws).map { " " + shellWord($0) } ?? ""
      try environment.actor.requireHuman(
        command: "silta ws edit" + target + " -F <file>", approved: global.approved)
      let text = try read(file)
      selected = try WorkspaceEditor.apply(
        text, slug: workspace ?? global.ws, store: environment.db, actor: environment.actor,
        identity: (environment.ids, environment.clock.now()), approved: global.approved)
    } else {
      selected = try WorkspaceEditor.edit(
        slug: workspace ?? global.ws, store: environment.db, actor: environment.actor,
        identity: (environment.ids, environment.clock.now()), approved: global.approved
      ) { file in
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // EDITOR is a human's shell command; the file path is passed as a positional argument.
        process.arguments = ["-c", "exec ${EDITOR:-vi} \"$1\"", "silta-editor", file.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
      }
    }
    var output = CommandOutput(
      text: selected.map { "Updated workspace \($0)." } ?? "No changes.",
      data: Data(workspace: selected), approvalUsed: true)
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
