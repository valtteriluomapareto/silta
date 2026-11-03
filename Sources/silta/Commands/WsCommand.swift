import ArgumentParser

struct WsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ws", abstract: "List, select and edit workspaces.",
    subcommands: [WsListCommand.self, WsUseCommand.self, WsEditCommand.self, WsShowCommand.self])

  @OptionGroup var global: GlobalOptions
}
