import ArgumentParser
import Foundation
import SiltaCore

struct AgentsSessionStartCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "session-start",
    abstract: "Claude SessionStart protocol; bounded stdin and silent failure.",
    shouldDisplay: false)
  static let workspaceSource = WorkspaceSource.none
  static let dataShape = BriefCommand.dataShape
  @OptionGroup var global: GlobalOptions

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let report = try await BriefService(environment: context.environment).resolve(
      path: URL(filePath: FileManager.default.currentDirectoryPath), workspace: global.ws,
      app: nil, task: nil, topics: [], budget: 800, hook: true)
    return CommandOutput(
      text: report.text, quiet: report.text, data: report, warnings: report.warnings
    )
    .reporting(report.location.workspace)
  }
}
