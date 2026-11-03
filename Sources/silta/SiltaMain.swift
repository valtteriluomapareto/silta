import ArgumentParser
import Foundation
import SiltaCore

/// The process entry point: parse, run, render, exit. Nothing else writes to stdout
/// or stderr (spec §20.1).
@main
enum SiltaMain {
  static func main() async {
    let rendered = await run(Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(Data(rendered.stdout.utf8))
    FileHandle.standardError.write(Data(rendered.stderr.utf8))
    exit(rendered.exitCode)
  }

  static func run(_ arguments: [String]) async -> Rendered {
    let mode = outputMode(arguments)
    let flags = Set(arguments.prefix { $0 != "--" })
    let timer = ContinuousClock()
    let started = timer.now
    do {
      let environment = try await SiltaEnvironment.system(
        environment: ProcessInfo.processInfo.environment,
        deterministic: flags.contains("--deterministic"),
        verbose: flags.contains("--verbose") ? .standardError : nil)
      let timestamp = environment.clock.now()
      let rendered = await execute(
        arguments, context: CommandContext(mode: mode, environment: environment))
      let elapsed = started.duration(to: timer.now).components
      let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
      var entry = LogEntry(
        timestamp: timestamp, command: commandPath(arguments),
        actor: environment.actor.description, exitCode: rendered.exitCode,
        milliseconds: milliseconds)
      entry.errorCode = rendered.errorCode
      entry.warnings = rendered.warningCodes
      entry.flags = ["--json", "--quiet", "--deterministic", "--verbose", "--help", "--version"]
        .filter { flags.contains($0) }
      environment.log.record(entry)
      return rendered
    } catch {
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
  static func execute(_ arguments: [String], context: CommandContext) async -> Rendered {
    let mode = context.mode
    var command: any ParsableCommand
    do {
      command = try SiltaCommand.parseAsRoot(arguments)
    } catch {
      return parseFailure(error, arguments: arguments, mode: mode)
    }
    guard let outputCommand = command as? any OutputCommand else {
      // The root itself: ArgumentParser answers with help.
      do {
        try command.run()
        return Rendered(stdout: "", stderr: "", exitCode: 0, errorCode: nil)
      } catch {
        return parseFailure(error, arguments: arguments, mode: mode)
      }
    }
    do {
      var output = try await outputCommand.execute(context)
      output.warnings = context.environment.warnings + output.warnings
      return OutputRouter.render(.success(output), mode: mode)
    } catch let error as any CodedError {
      let recovered = recovery(
        error, command: outputCommand, arguments: arguments, context: context)
      return OutputRouter.render(.failure(recovered), mode: mode)
    } catch {
      return OutputRouter.render(.failure(error), mode: mode)
    }
  }

  /// Keeps recovery tied to the failed command and the task's workspace.
  static func recovery(
    _ error: any CodedError, command: any OutputCommand,
    arguments: [String], context: CommandContext
  ) -> CommandFailure {
    let path = commandPath(arguments)
    if error.code == .busy { return CommandFailure(error: error, next: [path]) }
    var next = error.next
    if let task = error as? TaskError, task.code == .invalid { next = [path + " --help"] }
    var workspace = command.global.ws
    if workspace == nil, path.hasPrefix("silta task "), !(error is ActorError) {
      do { workspace = try WorkspaceSelection.resolve(in: context.environment.db) } catch {
        workspace = nil
      }
    }
    if let workspace {
      next = next.map {
        $0.hasPrefix("silta task ")
          ? "silta --ws " + shellWord(workspace) + String($0.dropFirst(5)) : $0
      }
    }
    return CommandFailure(error: error, next: next)
  }

  /// The output mode, read from the raw arguments so a parse error can still answer in
  /// JSON. ArgumentParser itself accepts the flags before or after the subcommand.
  /// Nothing after `--` counts.
  static func outputMode(_ arguments: [String]) -> OutputMode {
    let flags = arguments.prefix { $0 != "--" }
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

  /// The command being parsed, e.g. `silta task ls`: the subcommand names among the
  /// arguments, skipping flags.
  static func commandPath(_ arguments: [String]) -> String {
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
    return path.joined(separator: " ")
  }
}
