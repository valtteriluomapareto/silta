import ArgumentParser
import Foundation
import SiltaCore

struct InitCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize or scan repos; select with ws use; configuration editing is human-only.")

  static let dataShape = Shape.object([
    "workspace": .optional(.string), "next": .array(.string), "next_by": .string,
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup var global: GlobalOptions

  @Option(
    parsing: .upToNextOption,
    help: "Scan directories to two child levels; rescans only refresh registered paths.")
  var scan: [String] = []

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let env = context.environment
    let outcome: ScanOutcome?
    if scan.isEmpty {
      try env.db.initialize()
      outcome = nil
    } else {
      outcome = try await RepositoryScan.scan(
        scan.map { URL(filePath: $0) }, store: env.db,
        git: env.git, identity: (env.ids, env.clock.now()), workspace: global.ws)
    }
    let workspace = outcome?.workspace
    let edit =
      (workspace.map { "silta ws edit '" + $0 + "'" } ?? "silta ws edit")
      + " -F <file> --approved \"<the human's words>\""
    var text = workspace.map { "Initialized workspace \($0)." } ?? "Initialized database."
    if let workspace { text += "\nnext: silta ws use '\(workspace)'" }
    text += "\nask human: \(edit)"
    var output = CommandOutput(
      text: text, data: InitData(workspace: workspace, next: [edit], nextBy: "human"),
      warnings: outcome?.warnings ?? [])
    output.workspace = workspace
    return output
  }

}

private struct InitData: Encodable {
  let workspace: String?

  let next: [String]

  let nextBy: String

  enum CodingKeys: String, CodingKey {
    case workspace, next
    case nextBy = "next_by"
  }
}
