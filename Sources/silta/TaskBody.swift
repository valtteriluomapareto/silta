import ArgumentParser
import Foundation
import SiltaCore

/// Reads command bodies without putting their content into recovery commands.
struct TaskBody: ParsableArguments {
  @Option(name: [.customShort("m"), .long], help: "Supply the markdown body.")
  var message: String?

  @Option(name: .customShort("F"), help: "Read UTF-8 from a file, or - for stdin.")
  var file: String?

  @Flag(help: "Retain detected secrets (human-only; retry with -F <file>).")
  var allowSecret = false

  func read(actor: ActorID, command: String) throws -> String? {
    if allowSecret { try actor.requireHuman(command: command + " --allow-secret -F <file>") }
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
