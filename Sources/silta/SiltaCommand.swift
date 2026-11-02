import ArgumentParser
import SiltaCore

struct SiltaCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "silta",
    abstract: "A local context hub and backlog for coding agents.",
    version: SiltaVersion.current
  )

  @OptionGroup var global: GlobalOptions
}
