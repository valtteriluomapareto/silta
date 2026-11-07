import ArgumentParser
import Foundation
import SiltaCore

/// Reads command bodies without putting their content into recovery commands.
struct TaskBody: ParsableArguments {
  @Option(
    name: [.customShort("m"), .long], parsing: .unconditional,
    help: "Supply the markdown body; default is none.")
  var message: String?

  @Option(
    name: .customShort("F"), help: "Read UTF-8 from a file, or - for stdin; default is none.")
  var file: String?

  @Flag(help: "Retain detected secrets (human-only; use file input for a body retry).")
  var allowSecret = false

  /// The body flag passed, as an approval row names it: `-m <text>` or `-F <file>`.
  var flag: String? {
    message != nil ? "-m <text>" : file != nil ? "-F <file>" : nil
  }

  func read(actor: ActorID, command: String, approved: String? = nil) throws -> String? {
    if allowSecret {
      try actor.requireHuman(command: command + " --allow-secret -F <file>", approved: approved)
    }
    return try readContent(command: command)
  }

  /// Reads content without consent checks; state-dependent writers gate their changed
  /// transaction instead of asking for permission for a no-op.
  func readContent(command: String) throws -> String? {
    guard message == nil || file == nil else {
      throw UsageError.invalid(message: "Use either -m or -F, not both.", command: command)
    }
    guard let file else { return message }
    do {
      let data =
        try file == "-"
        ? FileHandle.standardInput.readToEnd() ?? Data()
        : Data(contentsOf: URL(filePath: file))
      guard let text = String(data: data, encoding: .utf8) else { throw TaskError.input }
      return text
    } catch {
      throw TaskError.input
    }
  }
}
