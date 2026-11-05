import ArgumentParser
import Foundation
import SiltaCore

struct SessionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "session",
    abstract: "Read current-actor handoff needs.", subcommands: [SessionCheckCommand.self])
  @OptionGroup var global: GlobalOptions
}
