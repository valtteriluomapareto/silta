import ArgumentParser
import Foundation
import SiltaCore

struct SessionCheckCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Read fresh own claims needing handoff across all workspaces.",
    discussion: "Read-only; never initializes or migrates. Creation or claim alone does not need "
      + "handoff. Own plan, step, discussion and other task writes after handoff do. "
      + "Refreshes do not erase earlier writes; expired or foreign claims are omitted.")
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = Shape.object([
    "tasks": .array(.object(["workspace": .string, "ref": .string]))
  ])
  @OptionGroup(title: "Global Options") var global: GlobalOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let result = SessionCheckData(
      tasks: try SessionService(environment: context.environment).check())
    let text =
      result.tasks.isEmpty
      ? "No handoff needed."
      : "Handoffs needed; provide each body on stdin:\n"
        + result.tasks.map(\.command).joined(separator: "\n")
    return CommandOutput(text: text, quiet: text, data: result)
  }
}

struct SessionCheckData: Encodable, Sendable { let tasks: [SessionHandoff] }
