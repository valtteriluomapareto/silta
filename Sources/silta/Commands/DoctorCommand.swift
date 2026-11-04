import ArgumentParser
import SiltaCore

struct DoctorCommand: OutputCommand {
  static let workspaceSource = WorkspaceSource.none
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Diagnose database, git and data across all workspaces without repairs.",
    discussion:
      "--ws does not filter this global report. "
      + "Unavailable install, index and app checks are explicitly skipped."
  )
  static let dataShape = Shape.object([
    "checks": .array(
      .object([
        "id": .string, "status": .string, "message": .string, "next": .array(.string),
      ]))
  ])

  @OptionGroup var global: GlobalOptions

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let env = context.environment
    let report = await DoctorService.inspect(
      store: env.db, home: env.home.url, git: env.git, at: env.clock.now())
    var output = CommandOutput(text: report.text, quiet: report.text, data: report)
    if report.checks.contains(where: { $0.status == "fail" }) {
      output.failure = DoctorFailure(report: report)
    }
    return output
  }
}
