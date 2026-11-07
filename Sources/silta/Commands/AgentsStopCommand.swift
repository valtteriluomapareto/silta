import ArgumentParser
import Foundation
import SiltaCore

struct AgentsStopCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop",
    abstract: "Claude Stop protocol; silent failure and loop guard.", shouldDisplay: false)
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = SessionCheckCommand.dataShape
  @OptionGroup(title: "Global Options") var global: GlobalOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let result = SessionCheckData(
      tasks: try SessionService(environment: context.environment).check())
    var text = ""
    if !result.tasks.isEmpty {
      var reason =
        "Leave a Silta handoff before stopping. "
        + "Run each command with a short handoff body on stdin:\n"
        + result.tasks.prefix(5).map(\.command).joined(separator: "\n")
      if result.tasks.count > 5 { reason += "\nMore: silta session check" }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard
        let json = String(data: try encoder.encode(StopDecision(reason: reason)), encoding: .utf8)
      else { throw TaskError.input }
      text = json
    }
    return CommandOutput(text: text, quiet: text, data: result)
  }
}

private struct StopDecision: Encodable, Sendable {
  let decision = "block"
  let reason: String
}
