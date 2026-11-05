import ArgumentParser
import SiltaCore

struct SiltaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "silta",
    abstract: "A local context hub and backlog for coding agents.",
    version: SiltaVersion.current,
    subcommands: [
      SchemaCommand.self, WsCommand.self, InitCommand.self, RepoCommand.self, TaskCommand.self,
      CodeCommand.self, WhereCommand.self, DoctorCommand.self, CommentCommand.self,
      BriefCommand.self, InboxCommand.self, GuideCommand.self, AgentsCommand.self,
      SessionCommand.self, StatusCommand.self,
    ],
    // Bare `silta` prints the status line; help, version and usage errors stay the root's.
    defaultSubcommand: StatusCommand.self
  )

  @OptionGroup var global: GlobalOptions
}
