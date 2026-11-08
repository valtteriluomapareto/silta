import ArgumentParser
import SiltaCore

struct SiltaCommand: ParsableCommand {
  static func parseRoot(_ arguments: [String]) throws -> any ParsableCommand {
    if let first = arguments.first, arguments.contains("--help"), !first.hasPrefix("-"),
      first != "help", !configuration.subcommands.contains(where: { $0._commandName == first })
    {
      throw ValidationError("Unexpected argument '\(first)'")
    }
    return try parseAsRoot(arguments)
  }

  static let configuration = CommandConfiguration(
    commandName: "silta",
    abstract: "A local context hub and backlog for coding agents.",
    version: SiltaVersion.current,
    subcommands: [
      SchemaCommand.self, WsCommand.self, InitCommand.self, RepoCommand.self, TaskCommand.self,
      CodeCommand.self, WhereCommand.self, DoctorCommand.self, CommentCommand.self,
      BriefCommand.self, InboxCommand.self, GuideCommand.self, AgentsCommand.self,
      SessionCommand.self, StatusCommand.self,
      ExportCommand.self, RestoreCommand.self, BackupCommand.self,
    ],
    // Bare `silta` prints the status line; help, version and usage errors stay the root's.
    defaultSubcommand: StatusCommand.self
  )

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
