import ArgumentParser
import SiltaCore

/// Shared selection flags and output for the four concrete code reads.
struct CodeOptions: ParsableArguments {
  @Flag(help: "Read the app's production ref; default is off.")
  var prod = false

  @Flag(help: "Fetch first; default is off. Failures stop the read.")
  var fetch = false

  static let dataShape = Shape.object([
    "app": .string, "ref": .string, "sha": .string, "output": .string,
  ])

  func execute(
    _ operation: CodeRead, target: String, global: GlobalOptions,
    context: CommandContext
  ) async throws -> CommandOutput {
    let env = context.environment
    let workspace = try context.workspace(global.ws)
    let result = try await CodeService(
      workspace: workspace, store: env.db, git: env.git, at: env.clock.now()
    )
    .read(operation, target: target, prod: prod, fetch: fetch)
    let text = "\(result.app)@\(result.ref) \(result.sha)\n" + result.output
    return CommandOutput(text: text, quiet: text, data: result, warnings: result.warnings)
      .reporting(workspace)
  }
}
