import ArgumentParser
import Foundation
import SiltaCore

extension SiltaMain {
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
    if ReferenceHelpCommand.arguments(in: arguments) != nil {
      return ("silta help refs", ReferenceHelpCommand.self)
    }
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
