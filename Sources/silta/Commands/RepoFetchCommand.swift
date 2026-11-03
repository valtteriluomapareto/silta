import ArgumentParser
import SiltaCore

struct RepoFetchCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "fetch",
    abstract: "Fetch a repo, or all registered repos in the workspace, without prompting.")

  static let dataShape = Shape.object(["repos": .array(.string)])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The repository slug; omitted means all registered repos.")
  var repo: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let env = context.environment
    let workspace = try context.workspace(global.ws)
    let repos = try await RepositoryFetch.fetch(
      repo, workspace: workspace, store: env.db,
      git: env.git, at: env.clock.now())
    return CommandOutput(
      text: repos.map { "Fetched \($0)." }.joined(separator: "\n"), data: Data(repos: repos)
    ).reporting(workspace)
  }

  private struct Data: Encodable {
    let repos: [String]
  }
}
