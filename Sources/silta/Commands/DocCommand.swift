import ArgumentParser

struct DocCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doc", abstract: "Read and edit stored documents.",
    subcommands: [
      DocShowCommand.self, DocListCommand.self, DocEditCommand.self, DocArchiveCommand.self,
    ])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
