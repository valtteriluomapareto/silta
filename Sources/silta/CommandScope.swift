import ArgumentParser
import SiltaCore

/// The workspace and app a command's log line names (spec §19): identities that
/// exist in storage, never raw caller values.
struct CommandScope {
  var workspace: String?

  var app: String?

  /// The workspace a successful command reports creating or changing, otherwise the
  /// one it resolves when it acts on a workspace.
  static func resolve(_ command: any OutputCommand, reported: String?, store: DatabaseStore)
    -> Self
  {
    if let reported { return Self(workspace: reported) }
    guard type(of: command).actsOnWorkspace else { return Self() }
    return resolve(command.workspaceSlug, app: command.appSlug, store: store)
  }

  /// A malformed call to a command that acts on a workspace names its `--ws` or the
  /// current workspace, read through the same global and opaque-body parser rules.
  static func usage(
    _ arguments: [String], command: any ParsableCommand.Type, store: DatabaseStore
  ) -> Self {
    guard (command as? any OutputCommand.Type)?.actsOnWorkspace == true else { return Self() }
    let parsed: UsageArguments
    do { parsed = try UsageArguments.parse(arguments) } catch { return Self() }
    return resolve(parsed.global.ws, app: nil, store: store)
  }

  private static func resolve(_ slug: String?, app: String?, store: DatabaseStore) -> Self {
    let workspace: String
    do { workspace = try WorkspaceSelection.resolve(slug, in: store) } catch {
      // A workspace that doesn't exist stays out of the log; the command reports it.
      return Self()
    }
    guard let app else { return Self(workspace: workspace) }
    do {
      return Self(
        workspace: workspace, app: try WorkspaceSelection.app(app, workspace: workspace, in: store))
    } catch {
      // Failed app attribution keeps the known workspace and can't change the result.
      return Self(workspace: workspace)
    }
  }
}

/// Keeps rendering and resolved attribution together at the process boundary.
struct CommandExecution {
  let rendered: Rendered

  var scope = CommandScope()
}

/// Reads known options while ArgumentParser retains the malformed command remainder.
private struct UsageArguments: ParsableArguments {
  @OptionGroup var global: GlobalOptions

  @OptionGroup var body: TaskBody

  @Argument(parsing: .allUnrecognized) var remainder: [String] = []
}
