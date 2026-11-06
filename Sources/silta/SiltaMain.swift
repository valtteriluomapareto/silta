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
    do {
      guard let snapshot = try environmentSnapshot(arguments, hook: hookDeadline != nil) else {
        return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
      }
      let environment: SiltaEnvironment
      if let hookDeadline {
        environment = try await BriefHook.environment(
          snapshot, deterministic: flags.contains("--deterministic"), deadline: hookDeadline,
          watchdog: watchdog)
      } else {
        environment = try await SiltaEnvironment.system(
          environment: snapshot, deterministic: flags.contains("--deterministic"),
          verbose: flags.contains("--verbose") ? .standardError : nil)
      }
      watchdog?.prepare(environment: environment)
      let timestamp = environment.clock.now()
      let execution = await execute(
        arguments, context: CommandContext(mode: mode, environment: environment))
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
      if let informational = informationalResult(arguments, mode: mode) { return informational }
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
      "--approved", "--json", "--quiet", "--deterministic", "--verbose", "--help", "--version",
    ]
    .filter { flags.contains($0) }
  }

  /// Configuration failures must not obstruct help or version discovery.
  static func informationalResult(_ arguments: [String], mode: OutputMode) -> Rendered? {
    do {
      var command = try SiltaCommand.parseAsRoot(arguments)
      guard !(command is any OutputCommand) else { return nil }
      try command.run()
      return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
    } catch {
      guard SiltaCommand.exitCode(for: error) == .success else { return nil }
      return parseFailure(error, arguments: arguments, mode: mode)
    }
  }

  /// Parses and executes using the environment already assembled by the command boundary.
  static func execute(_ arguments: [String], context: CommandContext) async -> CommandExecution {
    let mode = context.mode
    var command: any ParsableCommand
    do {
      command = try SiltaCommand.parseAsRoot(arguments)
    } catch {
      let store = context.environment.db
      let scope =
        SiltaCommand.exitCode(for: error) == .success
        ? CommandScope()
        : CommandScope.usage(arguments, command: parsed(arguments).command, store: store)
      return CommandExecution(
        rendered: parseFailure(error, arguments: arguments, mode: mode), scope: scope)
    }
    guard let outputCommand = command as? any OutputCommand else {
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
    } catch let error as any CodedError {
      let recovered = recovery(
        error, command: outputCommand, arguments: arguments, context: context)
      return CommandExecution(
        rendered: OutputRouter.render(.failure(recovered), mode: mode),
        scope: CommandScope.failure(outputCommand, store: store),
        command: loggedPath(arguments, outputCommand))
    } catch {
      return CommandExecution(
        rendered: OutputRouter.render(.failure(error), mode: mode),
        scope: CommandScope.failure(outputCommand, store: store),
        command: loggedPath(arguments, outputCommand))
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
    if let edit = command as? WsEditCommand, error is WorkspaceError, error.code != .notFound {
      next = workspaceRecovery(error, edit: edit, context: context)
    }
    var workspace = command.global.ws
    let usesWorkspace =
      path.hasPrefix("silta task ") || path == "silta comment"
      || path.hasPrefix("silta comment ")
    if workspace == nil, usesWorkspace,
      !(error is ActorError)
    {
      do { workspace = try WorkspaceSelection.resolve(in: context.environment.db) } catch {
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
      do { target = try WorkspaceSelection.resolve(in: context.environment.db) } catch {
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
