import ArgumentParser
import SiltaCore

struct CodeGrepCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "grep",
    abstract: "Search committed text, returning app-relative paths and line numbers.",
    discussion: "Find Acme references: silta code grep api \"Acme API\"")
  static let dataShape = CodeOptions.dataShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var options: CodeOptions
  @Argument(help: "App slug, optionally followed by @ref.") var target: String
  @Argument(help: "Extended regular expression (git grep -E); put option-like ones after --.")
  var pattern: String
  @Argument(help: "Optional relative wildcard pathspec; a leading : (Git magic) is unsupported.")
  var pathspec: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    try await options.execute(
      .grep(pattern, pathspec: pathspec), target: target, global: global, context: context)
  }
}
