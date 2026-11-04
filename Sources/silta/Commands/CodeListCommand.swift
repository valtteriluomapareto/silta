import ArgumentParser
import SiltaCore

struct CodeListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List immediate committed names in an app-relative directory.")
  static let dataShape = CodeOptions.dataShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @OptionGroup var options: CodeOptions
  @Argument(help: "App slug, optionally followed by @ref.") var target: String
  @Argument(help: "Optional app-relative literal directory.") var directory: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    try await options.execute(.list(directory), target: target, global: global, context: context)
  }
}
