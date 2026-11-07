import ArgumentParser
import Foundation
import SiltaCore

/// `silta status`, which bare `silta` runs (spec §16).
struct StatusCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Print a one-line status: workspace, app, inbox count and your claimed tasks.",
    discussion: "Bare silta runs this. It is a read: no fetch, no index write. "
      + "inbox counts what silta inbox shows for you; claimed lists your exact session's claims.")
  static let workspaceSource = WorkspaceSource.location
  static let dataShape = Shape.object([
    "location": .string, "workspace": .optional(.string), "app": .optional(.string),
    "inbox": .optional(.int),
    "claimed": .optional(.array(.object(["ref": .string, "title": .string]))),
  ])

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let report = try await StatusService(environment: context.environment).resolve(
      path: URL(filePath: FileManager.default.currentDirectoryPath), workspace: global.ws)
    let text = Self.line(report)
    return CommandOutput(text: text, quiet: text, data: report).reporting(report.workspace)
  }

  private static func line(_ report: StatusReport) -> String {
    guard let workspace = report.workspace, let inbox = report.inbox,
      let claimed = report.claimed
    else {
      return "No workspace here; next: silta " + (report.inRepository ? "where" : "ws ls")
    }
    let refs = claimed.isEmpty ? "none" : claimed.map(\.ref).joined(separator: " ")
    let line =
      "workspace \(workspace), app \(report.app ?? "(\(report.location))"), inbox \(inbox), "
      + "claimed \(refs)"
    return report.location == "unresolved" ? line + "; next: silta where" : line
  }
}
