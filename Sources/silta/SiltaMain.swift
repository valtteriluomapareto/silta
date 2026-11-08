import ArgumentParser
import Foundation
import SiltaCore

/// The process entry point: parse, run, render, exit. Nothing else writes to stdout
/// or stderr (spec §20.1).
@main
enum SiltaMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let started = ContinuousClock.now
    let hook = BriefHook.requested(arguments)
    let deadline = hook ? BriefHook.deadline(startedAt: started) : nil
    let watchdog =
      hook
      ? HookWatchdog(
        command: commandPath(arguments),
        flags: commandPath(arguments) == "silta brief" ? ["--hook"] : []) : nil
    let flags = Set(withoutApprovalValues(arguments).prefix { $0 != "--" })
    watchdog?.prepare(
      snapshot: ProcessInfo.processInfo.environment,
      deterministic: flags.contains("--deterministic"))
    let rendered = await run(arguments, hookDeadline: deadline, watchdog: watchdog)
    watchdog?.cancel()
    FileHandle.standardOutput.write(Data(rendered.stdout.utf8))
    FileHandle.standardError.write(Data(rendered.stderr.utf8))
    exit(rendered.exitCode)
  }

  static func run(
    _ arguments: [String], hookDeadline: BriefHookDeadline? = nil,
    watchdog: HookWatchdog? = nil
  ) async
    -> Rendered
  {
    let mode = outputMode(arguments)
    let flags = Set(withoutApprovalValues(arguments).prefix { $0 != "--" })
    let timer = ContinuousClock()
    let started = timer.now
    let parseResult = parseCommand(arguments)
    if let rendered = informationalResult(parseResult, arguments: arguments, mode: mode) {
      return rendered
    }
    do {
      guard let snapshot = try environmentSnapshot(arguments, hook: hookDeadline != nil) else {
        return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
      }
      let environment = try await makeEnvironment(
        snapshot, flags: flags, hookDeadline: hookDeadline, watchdog: watchdog)
      watchdog?.prepare(environment: environment)
      let timestamp = environment.clock.now()
      let execution = await execute(
        arguments, parseResult: parseResult,
        context: CommandContext(mode: mode, environment: environment))
      let rendered = execution.rendered
      let milliseconds = elapsedMilliseconds(started.duration(to: timer.now))
      var entry = LogEntry(
        timestamp: timestamp, command: execution.command ?? commandPath(arguments),
        actor: environment.actor.description, exitCode: hookDeadline == nil ? rendered.exitCode : 0,
        milliseconds: milliseconds)
      entry.workspace = execution.scope.workspace
      entry.app = execution.scope.app
      entry.errorCode = rendered.errorCode
      entry.warnings = rendered.warningCodes
      entry.flags = logFlags(flags)
      entry.sessionMatchesActor = suppliedSession(environment.actor, hook: hookDeadline != nil)
      if hookDeadline != nil {
        return completeHook(rendered, entry: entry, watchdog: watchdog, log: environment.log)
      }
      environment.log.record(entry)
      return rendered
    } catch {
      if hookDeadline != nil {
        watchdog?.failed(milliseconds: elapsedMilliseconds(started.duration(to: timer.now)))
        return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
      }
      if case .failure(let error) = parseResult {
        return parseFailure(error, arguments: arguments, mode: mode)
      }
      return OutputRouter.render(.failure(error), mode: mode)
    }
  }

  private static func completeHook(
    _ rendered: Rendered, entry: LogEntry,
    watchdog: HookWatchdog?, log: any Log
  ) -> Rendered {
    let completion = BriefHookCompletion(rendered: rendered, entry: entry)
    if let watchdog { watchdog.finish(completion.entry) } else { log.record(completion.entry) }
    return completion.rendered
  }

  private static func suppliedSession(_ actor: ActorID, hook: Bool) -> Bool? {
    guard !hook, case .agent(_, let session) = actor else { return nil }
    return ProcessInfo.processInfo.environment["SILTA_SESSION"] == session
  }

  private static func makeEnvironment(
    _ snapshot: [String: String], flags: Set<String>, hookDeadline: BriefHookDeadline?,
    watchdog: HookWatchdog?
  ) async throws -> SiltaEnvironment {
    if let hookDeadline {
      return try await BriefHook.environment(
        snapshot, deterministic: flags.contains("--deterministic"), deadline: hookDeadline,
        watchdog: watchdog)
    }
    return try await SiltaEnvironment.system(
      environment: snapshot, deterministic: flags.contains("--deterministic"),
      verbose: flags.contains("--verbose") ? .standardError : nil)
  }

  private static func environmentSnapshot(_ arguments: [String], hook: Bool) throws -> [String:
    String]?
  {
    let snapshot = ProcessInfo.processInfo.environment
    let path = commandPath(arguments)
    if hook && (path == "silta agents session-start" || path == "silta agents stop") {
      return try AgentHook.environment(snapshot, stop: path == "silta agents stop")
    }
    return snapshot
  }

  private static func elapsedMilliseconds(_ duration: Duration) -> Int {
    let elapsed = duration.components
    return Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
  }

  private static func logFlags(_ flags: Set<String>) -> [String] {
    return [
      "--approved", "--json", "--quiet", "--deterministic", "--verbose",
    ]
    .filter { flags.contains($0) }
  }

  /// Executes the parse result using the environment assembled by the command boundary.
  static func execute(
    _ arguments: [String], parseResult: Result<any ParsableCommand, any Error>,
    context: CommandContext
  ) async -> CommandExecution {
    var context = context
    let mode = context.mode
    var command: any ParsableCommand
    switch parseResult {
    case .success(let parsedCommand):
      command = parsedCommand
    case .failure(let error):
      let store = context.environment.db
      let scope =
        SiltaCommand.exitCode(for: error) == .success
        ? CommandScope()
        : CommandScope.usage(arguments, command: parsed(arguments).command, store: store)
      return CommandExecution(
        rendered: parseFailure(error, arguments: arguments, mode: mode), scope: scope)
    }
    guard var outputCommand = command as? any OutputCommand else {
      // The root or a command group: ArgumentParser answers with help.
      do {
        try command.run()
        return CommandExecution(
          rendered: Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil))
      } catch {
        return CommandExecution(rendered: parseFailure(error, arguments: arguments, mode: mode))
      }
    }
    let store = context.environment.db
    let explicitWorkspace = outputCommand.global.ws
    do {
      try await prepareWorkspace(&outputCommand, context: &context)
    } catch {
      context.environment.workspaceSelection = .failure(error)
    }
    do {
      var output = try await outputCommand.execute(context)
      let approvalWarnings = context.environment.actor.approvalWarnings(
        outputCommand.global.approved, used: output.approvalUsed)
      output.warnings += approvalWarnings.filter { warning in
        !output.warnings.contains(where: { $0.code == warning.code })
      }
      output.warnings = context.environment.warnings + output.warnings
      return CommandExecution(
        rendered: OutputRouter.render(.success(output), mode: mode),
        scope: CommandScope.success(outputCommand, workspace: output.workspace, store: store),
        command: loggedPath(arguments, outputCommand))
    } catch {
      return failedExecution(
        error, command: outputCommand,
        explicitWorkspace: explicitWorkspace, arguments: arguments, context: context)
    }
  }

  /// The name the log gives a command: the root's default command, which bare `silta`
  /// runs, keeps the name `silta schema` lists for it (spec §19).
  static func loggedPath(_ arguments: [String], _ command: any OutputCommand) -> String {
    let path = commandPath(arguments)
    return path == "silta" ? path + " " + type(of: command)._commandName : path
  }

  /// Keeps recovery tied to the failed command and intended workspace.
  static func recovery(
    _ error: any CodedError, command: any OutputCommand,
    arguments: [String], context: CommandContext
  ) -> CommandFailure {
    let path = commandPath(arguments)
    if error.code == .busy {
      return CommandFailure(error: error, next: [(command as? ExportCommand)?.retryCommand ?? path])
    }
    var next = error.next
    let ownNext =
      if case .step = error as? TaskError { true } else {
        (error as? CommentError)?.hasConcreteInvalidNext == true
      }
    if error.code == .invalid, !ownNext,
      error is TaskError || error is ActorError || error is CommentError
    {
      next = [path + " --help"]
    }
    if let edit = command as? TaskEditCommand, let taskError = error as? TaskError,
      taskError == .input
    {
      next = ["silta task edit " + shellWord(edit.ref) + " --print", path + " --help"]
    }
    if let edit = command as? WsEditCommand, error is WorkspaceError,
      error.code != .notFound, error.code != .ambiguousLocation
    {
      next = workspaceRecovery(error, edit: edit, context: context)
    }
    var workspace = command.global.ws
    let usesWorkspace =
      path.hasPrefix("silta task ") || path == "silta comment"
      || path.hasPrefix("silta comment ")
    if workspace == nil, usesWorkspace,
      !(error is ActorError)
    {
      do {
        workspace = try WorkspaceSelection.resolve(
          in: context.environment.db, prepared: context.environment.workspaceSelection)
      } catch {
        workspace = nil
      }
    }
    if let workspace {
      next = next.map {
        if $0 == "silta ws show" { return "silta ws show " + shellWord(workspace) }
        return $0.hasPrefix("silta task ") || $0.hasPrefix("silta comment ")
          ? workspaceCommand($0, workspace: workspace) : $0
      }
    }
    return CommandFailure(error: error, next: next)
  }

  /// Repairs the intended workspace through file input, without an editor or quote echo.
  static func workspaceRecovery(
    _ error: any CodedError, edit: WsEditCommand, context: CommandContext
  ) -> [String] {
    var target = edit.workspace ?? edit.global.ws
    if target == nil {
      do {
        target = try WorkspaceSelection.resolve(
          in: context.environment.db, prepared: context.environment.workspaceSelection)
      } catch {
        target = nil
      }
    }
    let suffix = target.map { " " + shellWord($0) } ?? ""
    let repair = "silta ws edit" + suffix + " -F <file> --approved \"<the human's words>\""
    if target != nil, error.code == .invalid || error.code == .conflict {
      return ["silta ws show" + suffix, repair]
    }
    return [repair]
  }

}

extension SiltaMain {
  /// Captures selection once for synchronous services, recovery and attribution.
  /// Commands execute once even when preparation fails, preserving stdin and early gates.
  private static func prepareWorkspace(
    _ command: inout any OutputCommand, context: inout CommandContext
  ) async throws {
    let source = type(of: command).workspaceSource
    guard source == .option || source == .argument,
      command.global.ws == nil,
      (command as? any WorkspaceArgumentCommand)?.workspaceArgument == nil
    else { return }
    if command is WsEditCommand {
      try context.environment.actor.requireHuman(
        command: "silta ws edit -F <file>", approved: command.global.approved)
    }
    let selected = try await WorkspaceSelection.fallback(
      path: URL(filePath: FileManager.default.currentDirectoryPath),
      environment: context.environment)
    context.environment.workspaceSelection = .success(selected)
    command.global.ws = selected
  }

  private static func failedExecution(
    _ error: any Error, command: any OutputCommand,
    explicitWorkspace: String?, arguments: [String], context: CommandContext
  ) -> CommandExecution {
    var failure: any Error = error
    if let coded = failure as? any CodedError {
      var recoveryCommand = command
      // Approval hints retain caller selection; operation logs retain captured selection.
      if coded is ActorError { recoveryCommand.global.ws = explicitWorkspace }
      failure = recovery(coded, command: recoveryCommand, arguments: arguments, context: context)
    }
    return CommandExecution(
      rendered: OutputRouter.render(.failure(failure), mode: context.mode),
      scope: CommandScope.failure(
        command, store: context.environment.db, prepared: context.environment.workspaceSelection),
      command: loggedPath(arguments, command))
  }
}
