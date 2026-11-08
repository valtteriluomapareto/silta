import ArgumentParser

struct CodeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "code",
    abstract: "Read another app's committed code without checking out a branch.",
    subcommands: [
      CodeShowCommand.self, CodeGrepCommand.self, CodeLogCommand.self, CodeListCommand.self,
    ])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
