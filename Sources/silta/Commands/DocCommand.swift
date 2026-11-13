import ArgumentParser

struct DocCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doc", abstract: "Read stored documents and their revisions.",
    subcommands: [DocShowCommand.self, DocListCommand.self])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
