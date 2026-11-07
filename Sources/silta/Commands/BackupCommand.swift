import ArgumentParser
import SiltaCore

struct BackupCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "backup", abstract: "Create a whole-database SQLite snapshot.",
    discussion:
      "Includes every workspace, regardless of --ws. Keeps seven on-demand snapshots separately "
      + "from daily and pre-restore backups. Does not export or commit a text tree."
  )
  static let dataShape = Shape.object(["path": .string])
  static let workspaceSource = WorkspaceSource.none
  @OptionGroup(title: "Global Options") var global: GlobalOptions

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let environment = context.environment
    let result = try BackupService.backup(
      store: environment.db, home: environment.home.url, clock: environment.clock)
    return CommandOutput(text: "Backed up the whole database to \(result.path).", data: result)
  }
}
