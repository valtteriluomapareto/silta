import ArgumentParser
import SiltaCore

struct CodeLogCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "log", abstract: "List commit SHA and subject at the selected ref.")
  static let dataShape = CodeOptions.dataShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @OptionGroup var options: CodeOptions
  @Argument(help: "App slug, optionally followed by @ref.") var target: String
  @Argument(help: "Optional app-relative literal path.") var path: String?
  @Option(name: .customShort("n"), help: "Positive commit limit (default 20).") var count = 20

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    try await options.execute(
      .log(path, count: count), target: target, global: global, context: context)
  }
}
