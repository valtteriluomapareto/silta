import ArgumentParser
import Foundation
import SiltaCore

struct WsEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit", abstract: "Edit workspace YAML (human-only).")

  static let dataShape = Shape.object(["workspace": .optional(.string)])

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The workspace slug; defaults to the current workspace.")
  var workspace: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    let selected = try WorkspaceEditor.edit(
      slug: workspace ?? global.ws, store: environment.db, actor: environment.actor,
      identity: (environment.ids, environment.clock.now())
    ) { file in
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      // EDITOR is a human's shell command; the file path is passed as a positional argument.
      process.arguments = ["-c", "exec ${EDITOR:-vi} \"$1\"", "silta-editor", file.path]
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }
    return CommandOutput(
      text: selected.map { "Updated workspace \($0)." } ?? "No changes.",
      data: Data(workspace: selected))
  }

  private struct Data: Encodable {
    let workspace: String?
  }
}
