import ArgumentParser
import SiltaCore

struct DocTriageCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "triage",
    abstract: "Accept or reject document proposals atomically (human-only).",
    discussion: "Read each pinned proposal and diff before asking for one approval.\n"
      + "Stale proposals can be rejected; only acceptances need current bases.\n"
      + "Example: silta doc triage --accept doc:rules@2 --reject doc:rules@1")
  static let dataShape = Shape.object(["docs": .array(.object(["ref": .string, "state": .string]))])
  static let workspaceSource = WorkspaceSource.option
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Option(
    parsing: .upToNextOption, help: "Immutable proposal refs to accept; repeat or list several.")
  var accept: [String] = []
  @Option(
    parsing: .upToNextOption, help: "Immutable proposal refs to reject; repeat or list several.")
  var reject: [String] = []

  func authorize(_ context: CommandContext) throws {
    _ = try service(context).authorize(DocTriage(accept: accept, reject: reject))
  }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let result = try await service(context).triage(DocTriage(accept: accept, reject: reject))
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
