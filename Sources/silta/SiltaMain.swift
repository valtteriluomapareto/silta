import ArgumentParser
import Foundation
import SiltaCore

/// The process entry point: parse, run, render, exit. Nothing else writes to stdout
/// or stderr (spec §20.1).
@main
enum SiltaMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let hook = BriefHook.requested(arguments)
    let deadline = hook ? ContinuousClock().now.advanced(by: .milliseconds(1500)) : nil
    let watchdog = hook ? BriefHook.watchdog() : nil
    defer { watchdog?.cancel() }
    let rendered = await run(arguments, hookDeadline: deadline)
    FileHandle.standardOutput.write(Data(rendered.stdout.utf8))
    FileHandle.standardError.write(Data(rendered.stderr.utf8))
    exit(rendered.exitCode)
  }

  static func run(_ arguments: [String], hookDeadline: ContinuousClock.Instant? = nil) async
    -> Rendered
  {
    let mode = outputMode(arguments)
    let flags = Set(withoutApprovalValues(arguments).prefix { $0 != "--" })
    let timer = ContinuousClock()
    let started = timer.now
    do {
      let snapshot = ProcessInfo.processInfo.environment
      let environment: SiltaEnvironment
      if let hookDeadline {
        environment = try await BriefHook.environment(
          snapshot, deterministic: flags.contains("--deterministic"), deadline: hookDeadline)
      } else {
        environment = try await SiltaEnvironment.system(
          environment: snapshot, deterministic: flags.contains("--deterministic"),
          verbose: flags.contains("--verbose") ? .standardError : nil)
      }
      let timestamp = environment.clock.now()
      let execution = await execute(
        arguments, context: CommandContext(mode: mode, environment: environment))
      var rendered = execution.rendered
      let elapsed = started.duration(to: timer.now).components
      let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
      var entry = LogEntry(
        timestamp: timestamp, command: commandPath(arguments),
        actor: environment.actor.description, exitCode: hookDeadline == nil ? rendered.exitCode : 0,
        milliseconds: milliseconds)
      entry.workspace = execution.scope.workspace
      entry.app = execution.scope.app
      entry.errorCode = rendered.errorCode
      entry.warnings = rendered.warningCodes
      entry.flags = [
        "--approved", "--json", "--quiet", "--deterministic", "--verbose", "--help", "--version",
      ]
      .filter { flags.contains($0) }
      environment.log.record(entry)
      if let hookDeadline,
        rendered.exitCode != 0 || ContinuousClock().now >= hookDeadline
      {
        return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
      }
      if hookDeadline != nil { rendered.stderr = "" }
      return rendered
    } catch {
      if hookDeadline != nil {
        return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
      }
      if let informational = informationalResult(arguments, mode: mode) { return informational }
      return OutputRouter.render(.failure(error), mode: mode)
    }
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
        scope: CommandScope.success(outputCommand, workspace: output.workspace, store: store))
    } catch let error as any CodedError {
      let recovered = recovery(
        error, command: outputCommand, arguments: arguments, context: context)
      return CommandExecution(
        rendered: OutputRouter.render(.failure(recovered), mode: mode),
        scope: CommandScope.failure(outputCommand, store: store))
    } catch {
      return CommandExecution(
        rendered: OutputRouter.render(.failure(error), mode: mode),
        scope: CommandScope.failure(outputCommand, store: store))
    }
  }

  /// Keeps recovery tied to the failed command and intended workspace.
  static func recovery(
    _ error: any CodedError, command: any OutputCommand,
    arguments: [String], context: CommandContext
  ) -> CommandFailure {
    let path = commandPath(arguments)
    if error.code == .busy { return CommandFailure(error: error, next: [path]) }
    var next = error.next
    let ownNext =
      if case .step = error as? TaskError {
        true
      } else if case .bodyRequired = error as? CommentError { true } else { false }
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
          ? "silta --ws " + shellWord(workspace) + String($0.dropFirst(5)) : $0
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

  /// The output mode, read from the raw arguments so a parse error can still answer in
  /// JSON. ArgumentParser itself accepts the flags before or after the subcommand.
  /// Nothing after `--` counts.
  static func outputMode(_ arguments: [String]) -> OutputMode {
    let flags = withoutApprovalValues(arguments).prefix { $0 != "--" }
    return OutputMode(json: flags.contains("--json"), quiet: flags.contains("--quiet"))
  }

  /// Help and version are clean exits; anything else is a `usage` error.
  static func parseFailure(_ error: any Error, arguments: [String], mode: OutputMode) -> Rendered {
    if SiltaCommand.exitCode(for: error) == .success {
      let text = SiltaCommand.fullMessage(for: error)
      return Rendered(
        stdout: text.hasSuffix("\n") ? text : text + "\n", stderr: "", exitCode: 0,
        errorCode: nil)
    }
    let usage = UsageError.usage(
      message: oneLine(SiltaCommand.message(for: error)), command: commandPath(arguments))
    return OutputRouter.render(.failure(usage), mode: mode)
  }

  /// The longest parse message kept: it can quote arguments, which can carry bodies.
  static let maxMessage = 200

  /// ArgumentParser's message on one capped line.
  static func oneLine(_ message: String) -> String {
    let line = message.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return line.count > maxMessage ? line.prefix(maxMessage - 1) + "…" : line
  }

  /// Keeps approval words opaque to flag, command-path and diagnostic discovery.
  static func withoutApprovalValues(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var skipValue = false
    var positional = false
    for argument in arguments {
      if positional {
        result.append(argument)
        continue
      }
      if skipValue {
        skipValue = false
        continue
      }
      if argument == "--approved" {
        result.append(argument)
        skipValue = true
      } else if argument.hasPrefix("--approved=") {
        result.append("--approved")
      } else {
        result.append(argument)
        positional = argument == "--"
      }
    }
    return result
  }

  /// The command being parsed, e.g. `silta task ls`: the subcommand names among the
  /// arguments, skipping flags.
  static func commandPath(_ arguments: [String]) -> String {
    parsed(arguments).path
  }

  /// The command path and the deepest command type its names reach.
  static func parsed(_ arguments: [String]) -> (
    path: String, command: any ParsableCommand.Type
  ) {
    let arguments = withoutApprovalValues(arguments)
    var path = ["silta"]
    var command: any ParsableCommand.Type = SiltaCommand.self
    var skipValue = false
    for argument in arguments.prefix(while: { $0 != "--" }) {
      if skipValue {
        skipValue = false
        continue
      }
      if argument == "--ws" {
        skipValue = true
        continue
      }
      if argument.hasPrefix("-") { continue }
      guard
        let sub = command.configuration.subcommands.first(where: {
          // The name ArgumentParser itself matches, explicit or derived from the type.
          $0._commandName == argument
        })
      else { break }
      path.append(argument)
      command = sub
    }
    return (path.joined(separator: " "), command)
  }
}
