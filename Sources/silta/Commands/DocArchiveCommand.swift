import ArgumentParser
import SiltaCore

struct DocArchiveCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "archive",
    abstract: "Archive a document and remove its live attachments (human-only).",
    discussion: "Keeps revision history, comments and verification evidence.\n"
      + "An already archived doc without live attachments changes nothing.\n"
      + "Archive (human): silta doc archive rules")
  static let dataShape = DocEditCommand.dataShape
  static let workspaceSource = WorkspaceSource.option
  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "Doc slug or doc:slug, without a revision.") var slug: String

  func authorize(_ context: CommandContext) throws {
    _ = try DocWriteService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved
    ).authorizeArchive(slug)
  }

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let result = try DocWriteService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved
    ).archive(slug)
    return CommandOutput(
      text: result.ref + (result.changed ? " archived" : " already archived"),
      quiet: result.ref, data: result, warnings: result.warnings, approvalUsed: result.approvalUsed
    )
    .reporting(result.workspace)
  }
}
