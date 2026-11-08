import ArgumentParser

struct RepoCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "repo", abstract: "Operate on registered repositories.",
    subcommands: [RepoFetchCommand.self])

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
