import ArgumentParser
import SiltaCore

/// The workspace and app a command's log line names (spec §19): identities that
/// exist in storage, never raw caller values.
struct CommandScope {
  var workspace: String?

  var app: String?

  /// A successful command names only the workspace it reported resolving, so a command
  /// that reports none stays untagged.
  static func success(_ command: any OutputCommand, workspace: String?, store: DatabaseStore)
    -> Self
  {
    guard let workspace else { return Self() }
    return Self(workspace: workspace, app: app(command.appSlug, workspace: workspace, store: store))
  }

  /// A failed command names the workspace its source resolves to, when it still exists.
  static func failure(_ command: any OutputCommand, store: DatabaseStore) -> Self {
    switch type(of: command).workspaceSource {
    case .none: return Self()
    case .option, .location: return resolve(command.global.ws, app: command.appSlug, store: store)
    case .argument:
      guard let command = command as? any WorkspaceArgumentCommand else { return Self() }
      return resolve(command.workspaceArgument ?? command.global.ws, app: nil, store: store)
    }
  }

  /// A malformed call names `--ws` or the current workspace only when the command, or
  /// every command in a malformed group, takes its workspace from `--ws`; a missing or
  /// extra slug argument leaves the target unknown.
  static func usage(
    _ arguments: [String], command: any ParsableCommand.Type, store: DatabaseStore
  ) -> Self {
    guard source(of: command) == .option || source(of: command) == .location else { return Self() }
    let parsed: UsageArguments
    do { parsed = try UsageArguments.parse(arguments) } catch { return Self() }
    return resolve(parsed.global.ws, app: nil, store: store)
  }

  private static func source(of type: any ParsableCommand.Type) -> WorkspaceSource {
    if let command = type as? any OutputCommand.Type { return command.workspaceSource }
    let sources = type.configuration.subcommands.map(source(of:))
    return !sources.isEmpty && sources.allSatisfy { $0 == .option } ? .option : .none
  }

  private static func resolve(_ slug: String?, app appSlug: String?, store: DatabaseStore)
    -> Self
  {
    do {
      let workspace = try WorkspaceSelection.resolve(slug, in: store)
      return Self(workspace: workspace, app: app(appSlug, workspace: workspace, store: store))
    } catch {
      // A workspace that doesn't exist stays out of the log; the command reports it.
      return Self()
    }
  }

  private static func app(_ slug: String?, workspace: String, store: DatabaseStore) -> String? {
    guard let slug else { return nil }
    do { return try WorkspaceSelection.app(slug, workspace: workspace, in: store) } catch {
      // Failed app attribution keeps the known workspace and can't change the result.
      return nil
    }
  }
}

extension CommandContext {
  /// The workspace a command acts on: explicit or prepared `slug`, else current (spec §19).
  /// Commands resolve it once and pass it on, so the log names what they acted on.
  func workspace(_ slug: String?) throws -> String {
    try WorkspaceSelection.resolve(slug, in: environment.db)
  }

  /// The workspace task operations act on for `slug`, through `TaskService`'s own
  /// selection, so the log follows however a task command resolves its workspace.
  func taskWorkspace(_ slug: String?) -> String? {
    TaskService(environment: environment, workspace: slug).resolvedWorkspace()
  }
}

extension CommandOutput {
  /// This output, reporting the workspace the command resolved for its log line.
  func reporting(_ workspace: String?) -> Self {
    var output = self
    output.workspace = workspace
    return output
  }
}

/// Keeps rendering and resolved attribution together at the process boundary.
struct CommandExecution {
  let rendered: Rendered

  var scope = CommandScope()

  /// The command name the log line uses, when it differs from the parsed path.
  var command: String?
}

/// Reads known options while ArgumentParser retains the malformed command remainder.
private struct UsageArguments: ParsableArguments {
  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(parsing: .allUnrecognized) var remainder: [String] = []
}
