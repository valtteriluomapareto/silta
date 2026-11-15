import ArgumentParser
import SiltaCore

struct DocProposeCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "propose", abstract: "Submit a complete document proposal.",
    discussion: "Use -F for complete UTF-8 Markdown and -m to explain the proposal.\n"
      + "New docs need --title and --about; accepted metadata otherwise stays.\n"
      + "Submissions remain pending. Read with doc show or the human inbox.\n"
      + "Read editing rules with silta guide docs.\n"
      + "Example: silta doc propose api -F api.md -m Clarify --title API --about app:api")
  static let dataShape = Shape.object(["ref": .string])
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @Argument(help: "Doc slug or doc:slug, without a revision.") var slug: String
  @Option(
    name: .customShort("F"),
    help: .init(
      "Read complete UTF-8 Markdown from a file, or - for stdin.", valueName: "file"))
  var file: String?
  @Option(name: .customShort("m"), help: "Explain why this knowledge should be shared.")
  var why: String?
  @Option(help: "One line of at most 120 characters; required for a new doc.")
  var title: String?
  @Option(help: "Canonical map ref; repeat to replace the complete set; required for a new doc.")
  var about: [String] = []
  @Option(help: "Accepted owned revision used as the proposal's baseline.") var base: String?
  @Option(help: "Owned source task; otherwise use the session's sole live claim.") var task: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let request = DocProposalRequest(
      slug: slug, title: title, about: about.isEmpty ? nil : about, base: base, task: task, why: why
    )
    let input: (() throws -> String)? = file.map { file in
      { try DocInputFile.read(file, command: "silta doc propose") }
    }
    let result = try DocProposalService(
      environment: context.environment, workspace: global.ws, approved: global.approved
    ).propose(request, input: input)
    return CommandOutput(
      text: result.ref + " proposed", quiet: result.ref, data: result, warnings: result.warnings
    ).reporting(result.workspace)
  }
}
