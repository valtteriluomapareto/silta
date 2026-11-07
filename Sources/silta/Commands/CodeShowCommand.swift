import ArgumentParser
import SiltaCore

struct CodeShowCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "Read a committed file, optionally selecting lines.")
  static let dataShape = CodeOptions.dataShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var options: CodeOptions
  @Argument(help: "App slug, optionally followed by @ref.") var target: String
  @Argument(help: "App-relative literal file path.") var path: String
  @Option(help: "Positive line N or inclusive range A-B; default is at most 400 lines.")
  var lines: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    try await options.execute(
      .show(path, lines: lines), target: target, global: global, context: context)
  }
}
