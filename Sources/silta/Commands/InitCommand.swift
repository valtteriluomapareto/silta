import ArgumentParser
import Foundation
import SiltaCore

struct InitCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize or scan repos; select with ws use; configuration editing is human-only.",
    discussion: """
      `init --scan` discovers repos at the scan roots and at most two child levels, without \
      fetching. A new workspace's slug is the first directory's lowercased name unless --slug \
      names another; its task prefix is the slug's first two letters uppercased unless --prefix \
      names another. Chosen values keep their case, and task refs read <prefix>-<n> (AC-1). Both \
      use letters, digits, _ or -, starting and ending with a letter or digit, and the same \
      validation as `ws edit`. --prefix works without --slug, and --slug also names the \
      workspace. On a scan, --ws rescans an existing workspace, matching its slug without \
      regard to case, instead of naming a new one, so it accepts neither option. A clone \
      whose directory name normalizes to none is refused, because none means non-code \
      work, and the conflict names its path.

      Example: silta init --scan ~/acme/api ~/acme/web --slug acme --prefix AC
      """)

  static let dataShape = Shape.object([
    "workspace": .optional(.string), "next": .array(.string), "next_by": .string,
  ])

  static let workspaceSource = WorkspaceSource.none

  @OptionGroup var global: GlobalOptions

  @Option(
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Scan directories to two child levels; an existing workspace only refreshes the "
        + "repo paths already registered."))
  var scan: [String] = []

  @Option(
    help: ArgumentHelp(
      "Slug for a new workspace, kept as typed; defaults to the first directory's "
        + "lowercased name."))
  var slug: String?

  @Option(
    help: ArgumentHelp(
      "Task prefix for a new workspace, kept as typed; task refs read <prefix>-<n>, e.g. AC-1."))
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
