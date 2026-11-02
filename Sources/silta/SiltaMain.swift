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

  static func run(_ raw: [String]) -> Rendered {
    let (arguments, mode) = normalized(raw)
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

  /// Moves the global flags to the end, so they parse wherever they were written, and
  /// reads the output mode from them. Nothing after `--` is touched.
  static func normalized(_ raw: [String]) -> ([String], OutputMode) {
    let end = raw.firstIndex(of: "--") ?? raw.endIndex
    let head = raw[..<end]
    let globals = head.filter(GlobalOptions.names.contains)
    let rest = head.filter { !GlobalOptions.names.contains($0) }
    let mode = OutputMode(json: globals.contains("--json"), quiet: globals.contains("--quiet"))
    return (Array(rest) + Array(Set(globals)).sorted() + raw[end...], mode)
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

  /// ArgumentParser's message without its "Usage:" and "See …" lines, on one line.
  static func oneLine(_ message: String) -> String {
    message.split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("Usage:") && !$0.hasPrefix("See '") }
      .joined(separator: " ")
  }

  /// The command being parsed, e.g. `silta task ls`, from the leading subcommand names.
  static func commandPath(_ arguments: [String]) -> String {
    var path = ["silta"]
    var command: any ParsableCommand.Type = SiltaCommand.self
    for argument in arguments {
      guard
        let sub = command.configuration.subcommands.first(where: {
          $0._commandName == argument
        })
      else { break }
      path.append(argument)
      command = sub
    }
    return path.joined(separator: " ")
  }
}
