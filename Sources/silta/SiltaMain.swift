import ArgumentParser
import Foundation
import SiltaCore

/// The process entry point: parse, run, render, exit. Nothing else writes to stdout
/// or stderr (spec §20.1).
@main
enum SiltaMain {
  static func main() {
    let rendered = run(Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(Data(rendered.stdout.utf8))
    FileHandle.standardError.write(Data(rendered.stderr.utf8))
    exit(rendered.exitCode)
  }

  static func run(_ arguments: [String]) -> Rendered {
    let mode = outputMode(arguments)
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
    let context = CommandContext(mode: mode)
    return OutputRouter.render(Result { try outputCommand.execute(context) }, mode: mode)
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
    for argument in arguments.prefix(while: { $0 != "--" }) where !argument.hasPrefix("-") {
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
