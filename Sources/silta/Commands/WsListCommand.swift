import ArgumentParser
import Foundation
import SiltaCore

struct WsListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List workspace slugs, names and task prefixes.")

  static let dataShape = Shape.object([
    "workspaces": .array(
      .object([
        "slug": .string, "name": .string, "task_prefix": .string,
      ])),
    "next": .optional(.array(.string)), "next_by": .optional(.string),
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let workspaces = try WorkspaceSelection.list(in: context.environment.db)
    if workspaces.isEmpty {
      let cwd = URL(filePath: FileManager.default.currentDirectoryPath)
      let next = await RepositoryScan.firstScanCommand(in: cwd, git: context.environment.git)
      let text = "No workspaces. Choose the repositories to scan.\nnext: " + next
      return CommandOutput(
        text: text, quiet: text, data: WsListData(workspaces: [], next: [next], nextBy: "agent"))
    }
    let rows = workspaces.map { "\($0.slug)\t\(HumanText.line($0.name))\t\($0.taskPrefix)" }.joined(
      separator: "\n")
    return CommandOutput(
      text: "SLUG\tNAME\tTASK PREFIX\n" + rows, quiet: rows,
      data: WsListData(workspaces: workspaces, next: nil, nextBy: nil))
  }

}

private struct WsListData: Encodable {
  let workspaces: [WorkspaceSummary]
  let next: [String]?
  let nextBy: String?

  enum CodingKeys: String, CodingKey {
    case workspaces, next
    case nextBy = "next_by"
  }
}
