import ArgumentParser
import SiltaCore

struct SiltaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "silta",
    abstract: "A local context hub and backlog for coding agents.",
    version: SiltaVersion.current,
    subcommands: [
      SchemaCommand.self, WsCommand.self, InitCommand.self, RepoCommand.self, TaskCommand.self,
      CodeCommand.self, WhereCommand.self, DoctorCommand.self,
    ]
  )

  @OptionGroup var global: GlobalOptions
}
