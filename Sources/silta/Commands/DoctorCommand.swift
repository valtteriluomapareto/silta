import ArgumentParser
import Foundation
import SiltaCore

struct DoctorCommand: OutputCommand {
  static let workspaceSource = WorkspaceSource.none
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Diagnose database, git and data across all workspaces without repairs.",
    discussion: "--ws does not filter; --install skips SQLite and git.\n"
      + "Harness checks are read without launches; broad inspection can update SQLite "
      + "sidecars.\n"
      + "Snapshot recovery is human-only: stop clients; preserve home WAL/SHM sidecars.\n"
      + "Copy the snapshot as silta.db to a fresh home without old sidecars; doctor it.\n"
      + "`silta restore` consumes an export directory, not a snapshot."
  )
  static let dataShape = Shape.object([
    "checks": .array(
      .object([
        "id": .string, "status": .string, "message": .string, "next": .array(.string),
        "next_by": .string, "next_omitted": .int,
      ]))
  ])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Flag(help: "Inspect harness installation and logs only.")
  var install = false

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let env = context.environment
    var report: DoctorReport
    if install {
      report = DoctorReport(checks: [])
    } else {
      report = await DoctorService.inspect(
        store: env.db, home: env.home.url, git: env.git, at: env.clock.now())
    }
    let checks = AgentHealth.inspect(
      home: env.home.url, at: env.clock.now(), environment: ProcessInfo.processInfo.environment)
    report.checks.removeAll { $0.id.hasPrefix("install.") }
    let position = report.checks.firstIndex { $0.id.hasPrefix("index.") } ?? report.checks.endIndex
    report.checks.insert(contentsOf: checks, at: position)
    var output = CommandOutput(text: report.text, quiet: report.text, data: report)
    if report.checks.contains(where: { $0.status == .fail }) {
      output.failure = DoctorFailure(report: report)
    }
    return output
  }
}
