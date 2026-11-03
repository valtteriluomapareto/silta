import SiltaCore

/// Resolved identities for the existing command-log fields, never raw caller values.
struct CommandScope {
  var workspace: String?

  var app: String?

  static func resolve(
    _ command: any OutputCommand, context: CommandContext,
    output: CommandOutput? = nil
  ) -> Self {
    var hint = command.global.ws
    if let use = command as? WsUseCommand { hint = use.workspace }
    if let show = command as? WsShowCommand { hint = show.workspace ?? hint }
    if let edit = command as? WsEditCommand { hint = edit.workspace ?? hint }
    if let data = output?.data as? InitData { hint = data.workspace ?? hint }
    if let data = output?.data as? WsEditCommand.Data { hint = data.workspace ?? hint }
    let workspace: String
    do { workspace = try WorkspaceSelection.resolve(hint, in: context.environment.db) } catch {
      return Self()
    }
    do {
      let app: String?
      if let name = namedApp(command) {
        app = try WorkspaceSelection.app(name, workspace: workspace, in: context.environment.db)
      } else {
        let refs = references(command)
        let service = TaskService(environment: context.environment, workspace: workspace)
        let apps = try refs.map { try service.app(for: $0) }
        app = !apps.isEmpty && apps.allSatisfy { $0 == apps.first ?? nil } ? apps[0] : nil
      }
      return Self(workspace: workspace, app: app)
    } catch {
      // Failed app attribution retains the known workspace and cannot change the result.
      return Self(workspace: workspace)
    }
  }

  private static func namedApp(_ command: any OutputCommand) -> String? {
    if let add = command as? TaskAddCommand { return add.app }
    if let list = command as? TaskListCommand { return list.app }
    return nil
  }

  private static func workRef(_ command: any OutputCommand) -> String? {
    switch command {
    case let value as TaskShowCommand: value.ref
    case let value as TaskStartCommand: value.ref
    case let value as TaskSubmitCommand: value.ref
    case let value as TaskDoneCommand: value.ref
    case let value as TaskDropCommand: value.ref
    case let value as TaskPlanCommand: value.ref
    case let value as TaskEditCommand: value.ref
    default: nil
    }
  }

  private static func references(_ command: any OutputCommand) -> [String] {
    if let ref = workRef(command) { return [ref] }
    return switch command {
    case let value as TaskArchiveCommand: [value.ref]
    case let value as TaskKeepCommand: [value.ref]
    case let value as TaskLinkCommand: [value.ref]
    case let value as TaskPromoteCommand: [value.ref]
    case let value as TaskBlockCommand: [value.ref]
    case let value as TaskUnblockCommand: value.refs
    case let value as TaskTriageCommand: value.accept + value.drop
    case let value as TaskFromPlanCommand: value.parent.map { [$0] } ?? []
    default: []
    }
  }

}

/// Keeps rendering and resolved attribution together at the process boundary.
struct CommandExecution {
  let rendered: Rendered

  var scope = CommandScope()
}
