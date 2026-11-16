import ArgumentParser
import SiltaCore

struct DocTriageCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "triage",
    abstract: "Reject document proposals atomically (human-only).",
    discussion: "Read each pinned proposal before asking for one approval.\n"
      + "Rejections can be stale or concern removed targets.\n"
      + "Example: silta doc triage --reject doc:rules@2 doc:rules@3")
  static let dataShape = Shape.object(["docs": .array(.object(["ref": .string, "state": .string]))])
  static let workspaceSource = WorkspaceSource.option
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Option(
    parsing: .upToNextOption, help: "Immutable proposal refs to reject; repeat or list several.")
  var reject: [String] = []

  func authorize(_ context: CommandContext) throws {
    _ = try service(context).authorize(DocTriage(reject: reject))
  }

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let result = try service(context).triage(DocTriage(reject: reject))
    return CommandOutput(
      text: result.docs.map { $0.ref + " " + $0.state }.joined(separator: "\n"),
      quiet: result.docs.map(\.ref).joined(separator: "\n"), data: result,
      warnings: result.warnings, approvalUsed: result.approvalUsed
    ).reporting(result.workspace)
  }

  private func service(_ context: CommandContext) -> DocTriageService {
    DocTriageService(
      environment: context.environment, workspace: global.ws, approved: global.approved)
  }
}
