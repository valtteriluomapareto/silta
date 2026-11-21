import ArgumentParser
import SiltaCore

struct WsRemoveCommand: WorkspaceArgumentCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm", abstract: "Remove one workspace from a human terminal.",
    discussion: "Preview the removal without saving with --dry-run. The saved default and active "
      + "or uninspectable clone registrations require --allow-active. Removal saves a SQLite "
      + "backup and a workspace recovery tree.")

  static let dataShape = Shape.object([
    "workspace": .string, "name": .string, "dry_run": .bool, "saved_default": .bool,
    "counts": .array(.object(["kind": .string, "count": .int])),
    "registered_clones": .array(.string), "unresolved_clones": .optional(.array(.string)),
    "backup": .optional(.string),
    "recovery": .optional(.string), "next": .optional(.array(.string)),
    "next_by": .optional(.string),
  ])

  static let workspaceSource = WorkspaceSource.argument

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The exact workspace slug to remove.")
  var workspace: String

  @Flag(help: "Preview owned rows and active selection without saving.")
  var dryRun = false

  @Flag(help: "Allow removing the saved default or unregistering live or uninspectable clones.")
  var allowActive = false

  var workspaceArgument: String? { workspace }

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    if let explicit = global.ws, !explicit.utf8.elementsEqual(workspace.utf8) {
      throw UsageError.invalid(
        message: "Use the same workspace for --ws and the removal slug.", command: "silta ws rm")
    }
    let report = try await WorkspaceRemovalService(environment: context.environment)
      .remove(workspace, dryRun: dryRun, allowActive: allowActive)
    return CommandOutput(text: text(report), data: report).reporting(report.workspace)
  }

  private func text(_ report: WorkspaceRemovalReport) -> String {
    let verb = report.dryRun ? "Preview removal of" : "Removed"
    var lines = ["\(verb) \(HumanText.line(report.workspace)) (\(report.name))."]
    lines += report.counts.filter { $0.count > 0 }.map { "\($0.kind): \($0.count)" }
    if report.savedDefault {
      lines.append(
        report.dryRun ? "Saved default workspace." : "Cleared the saved default workspace.")
    }
    let unresolved = report.unresolvedClones ?? []
    if report.dryRun {
      if !report.registeredClones.isEmpty {
        lines.append("Registered clones: \(report.registeredClones.count).")
      }
      lines += unresolved.map { "Unresolved registered clone: " + $0 }
      if report.nextBy == NextBy.human.rawValue {
        lines.append("A human must use --allow-active to remove this workspace.")
      }
    } else {
      let count = report.registeredClones.count + unresolved.count
      if count > 0 {
        lines.append("Unregistered \(count) clone(s). Their files remain on disk.")
      }
    }
    if let backup = report.backup { lines.append("Backup: " + HumanText.line(backup)) }
    if let recovery = report.recovery { lines.append("Recovery tree: " + HumanText.line(recovery)) }
    let next = report.nextBy == NextBy.human.rawValue ? "ask human: " : "next: "
    lines += (report.next ?? []).map { next + $0 }
    return lines.joined(separator: "\n")
  }
}
