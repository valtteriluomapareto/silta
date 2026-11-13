import ArgumentParser
import SiltaCore

struct SiltaCommand: ParsableCommand {
  static func parseRoot(_ arguments: [String]) throws -> any ParsableCommand {
    var rest = arguments[...]
    while let argument = rest.first {
      rest = rest.dropFirst()
      if argument == "--ws" || argument == "--approved" {
        rest = rest.dropFirst()
        continue
      }
      if argument.hasPrefix("-") { continue }
      if arguments.contains("--help") || arguments.contains("-h"), argument != "help",
        !configuration.subcommands.contains(where: { $0.configuration.commandName == argument })
      {
        throw ValidationError("Unexpected argument '\(argument)'")
      }
      break
    }
    return try parseAsRoot(arguments)
  }

  static let configuration = CommandConfiguration(
    commandName: "silta",
    abstract: "A local context hub and backlog for coding agents.",
    version: SiltaVersion.current,
    subcommands: [
      SchemaCommand.self, WsCommand.self, InitCommand.self, RepoCommand.self, TaskCommand.self,
      CodeCommand.self, DocCommand.self, WhereCommand.self, DoctorCommand.self, CommentCommand.self,
      BriefCommand.self, InboxCommand.self, GuideCommand.self, AgentsCommand.self,
      SessionCommand.self, StatusCommand.self,
      ExportCommand.self, RestoreCommand.self, BackupCommand.self,
    ],
    // Bare `silta` prints the status line; help, version and usage errors stay the root's.
    defaultSubcommand: StatusCommand.self
  )

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
