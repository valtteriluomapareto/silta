import ArgumentParser
import Foundation
import SiltaCore

struct InitCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize Silta or scan local Git repositories into a workspace.",
    discussion: "`init --scan` scans roots and two child levels without fetching.\n"
      + "A new workspace derives its slug and task prefix from the first directory.\n"
      + "Values keep case, use letters, digits, _ or -, and start/end alphanumeric.\n"
      + "A --ws scan refreshes that workspace, matching slug without regard to case.\n"
      + "It takes no slug or prefix; a none-named clone is refused with its path.\n"
      + "Scan Acme repos: silta init --scan ~/acme/api ~/acme/web --slug acme --prefix AC")

  static let dataShape = Shape.object([
    "workspace": .optional(.string), "next": .array(.string), "next_by": .string,
    "repositories": .optional(.array(.string)), "apps": .optional(.array(.string)),
    "app_names": .optional(.array(.object(["slug": .string, "name": .string]))),
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
      "Task prefix; task refs read <prefix>-<n>, e.g. AC-1; defaults to the slug's first "
        + "two letters, uppercased."))
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
        git: env.git, identity: (env.ids, env.clock.now()), human: env.actor.isHuman)
    }
    return receipt(outcome, actor: env.actor)
  }

  private func receipt(_ outcome: ScanOutcome?, actor: ActorID) -> CommandOutput {
    let workspace = outcome?.workspace
    let next = workspace.map { "silta --ws " + shellWord($0) + " ws show" } ?? "silta init --help"
    var text =
      workspace.map { "Workspace \($0)." }
      ?? "Initialized database. Choose the repositories to scan."
    if let outcome {
      text +=
        "\nRepositories: "
        + (outcome.repositories.isEmpty ? "none" : outcome.repositories.joined(separator: ", "))
      let apps = outcome.apps.map { app in
        app.name.map { app.slug + " (" + HumanText.line($0) + ")" } ?? app.slug
      }
      text += "\nApps: " + (apps.isEmpty ? "none" : apps.joined(separator: ", "))
      text +=
        actor.isHuman
        ? "\nEdit from your terminal with silta ws edit " + shellWord(outcome.workspace) + "."
        : "\nAsk the human before editing the workspace configuration."
    }
    text += "\nnext: " + next
    let namedApps = outcome?.apps.filter { $0.name != nil } ?? []
    var output = CommandOutput(
      text: text,
      data: InitData(
        workspace: workspace, next: [next], nextBy: "agent",
        repositories: outcome?.repositories, apps: outcome?.apps.map(\.slug),
        appNames: namedApps.isEmpty ? nil : namedApps),
      warnings: outcome?.warnings ?? [])
    output.workspace = workspace
    return output
  }

}

private struct InitData: Encodable {
  let workspace: String?

  let next: [String]

  let nextBy: String

  let repositories: [String]?

  let apps: [String]?

  let appNames: [ScanOutcome.App]?

  enum CodingKeys: String, CodingKey {
    case workspace, next, repositories, apps
    case nextBy = "next_by"
    case appNames = "app_names"
  }
}
