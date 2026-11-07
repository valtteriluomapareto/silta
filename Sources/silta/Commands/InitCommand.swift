import ArgumentParser
import Foundation
import SiltaCore

struct InitCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize or scan repos; `ws edit` is human-only.",
    discussion: "`init --scan` scans roots and two child levels without fetching.\n"
      + "A new workspace derives its slug and task prefix from the first directory.\n"
      + "Values keep typed case and use letters, digits, _ or -, like `ws edit`.\n"
      + "A --ws scan refreshes that workspace, matching slug without regard to case.\n"
      + "It takes no slug or prefix; a none-named clone is refused with its path.\n"
      + "Example: silta init --scan ~/acme/api ~/acme/web --slug acme --prefix AC")

  static let dataShape = Shape.object([
    "workspace": .optional(.string), "next": .array(.string), "next_by": .string,
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Option(
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Scan directories to two child levels; default is none. An existing workspace only "
        + "refreshes registered repo paths."))
  var scan: [String] = []

  @Option(
    help: ArgumentHelp(
      "Slug for a new workspace; defaults to the first directory's lowercased name."))
  var slug: String?

  @Option(
    help: ArgumentHelp(
      "Task prefix; defaults to the slug's first two letters, uppercased."))
  var prefix: String?

  func execute(_ context: CommandContext) async throws -> CommandOutput {
    let env = context.environment
    if !scan.isEmpty, global.ws != nil, slug != nil || prefix != nil {
      throw UsageError.invalid(
        message: "--slug and --prefix apply only to a new workspace; --ws rescans an existing one.",
        command: "silta init")
    }
    if scan.isEmpty, slug != nil || prefix != nil {
      throw UsageError.invalid(
        message: "--slug and --prefix need --scan.", command: "silta init")
    }
    let outcome: ScanOutcome?
    if scan.isEmpty {
      try env.db.initialize()
      outcome = nil
    } else {
      let target: ScanTarget =
        if let workspace = global.ws {
          .rescan(workspace)
        } else if slug == nil, prefix == nil {
          .derived
        } else {
          .named(slug: slug, prefix: prefix)
        }
      outcome = try await RepositoryScan.scan(
        scan.map { URL(filePath: $0) }, target: target, store: env.db,
        git: env.git, identity: (env.ids, env.clock.now()))
    }
    let workspace = outcome?.workspace
    let edit =
      (workspace.map { "silta ws edit '" + $0 + "'" } ?? "silta ws edit")
      + " -F <file> --approved \"<the human's words>\""
    var text = workspace.map { "Initialized workspace \($0)." } ?? "Initialized database."
    if let workspace { text += "\nnext: silta ws use '\(workspace)'" }
    text += "\nask human: \(edit)"
    var output = CommandOutput(
      text: text, data: InitData(workspace: workspace, next: [edit], nextBy: "human"))
    output.workspace = workspace
    return output
  }

}

private struct InitData: Encodable {
  let workspace: String?

  let next: [String]

  let nextBy: String

  enum CodingKeys: String, CodingKey {
    case workspace, next
    case nextBy = "next_by"
  }
}
