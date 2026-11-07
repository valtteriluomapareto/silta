import ArgumentParser
import Foundation
import SiltaCore

struct TaskEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit task fields; approval is needed unless you hold its claim.",
    discussion: "`--print` outputs the document; edit it and return it with `-F`.\n"
      + "Sections: Title, Description, Acceptance, Plan and Result.\n"
      + "Each section is a tilde fence around its literal value.\n"
      + "Choose a fence longer than any tilde run in the values.\n"
      + "Empty fields hold one blank line; changed plans make revisions.\n"
      + "Agents can't clear a stored Plan or Result.")

  static let dataShape = Shape.object([
    "ref": .string, "status": .string, "document": .optional(.string),
  ])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String

  @Option(
    name: .customShort("F"),
    help: "Read UTF-8 Markdown from a file or stdin; default is none."
  )
  var file: String?

  @Flag(help: "Print the current document without editing; default is off.")
  var print = false

  @Flag(help: "Retain secrets with human approval; default is off.")
  var allowSecret = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let service = TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved,
      bodyFlag: file.map { _ in "-F <file>" })
    if print {
      guard file == nil, !allowSecret else {
        throw TaskError.invalid("--print only reads; use it without -F or --allow-secret.")
      }
      let printed = try service.editDocument(ref)
      return CommandOutput(
        text: printed.document, quiet: printed.document,
        data: Printed(
          ref: printed.task.ref, status: printed.task.status, document: printed.document)
      ).reporting(context.taskWorkspace(global.ws))
    }
    let result = try service.edit(ref, allowSecret: allowSecret) { original in
      if let file { return try read(file) }
      return try edit(original, environment: context.environment)
    }
    return TaskOutput.receipt(
      result.result,
      change: result.result.changed.isEmpty
        ? "unchanged" : "edited: " + result.result.changed.joined(separator: ", "),
      approvalUsed: result.approvalUsed
    ).reporting(context.taskWorkspace(global.ws))
  }

  private func read(_ path: String) throws -> String {
    do {
      let data =
        try path == "-"
        ? FileHandle.standardInput.readToEnd() ?? Data()
        : Data(contentsOf: URL(filePath: path))
      guard let text = String(data: data, encoding: .utf8) else { throw TaskError.input }
      return text
    } catch { throw TaskError.input }
  }

  private func edit(_ original: String, environment: SiltaEnvironment) throws -> String? {
    let name = try environment.ids.next(at: environment.clock.now())
    let path = FileManager.default.temporaryDirectory.appending(path: "silta-task-\(name).md")
    defer {
      // Cleanup cannot replace a successful save or the editor's original failure.
      try? FileManager.default.removeItem(at: path)  // Removal is best effort for a temporary file.
    }
    do {
      try original.write(to: path, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
      process.arguments = ["-c", "exec " + editor + " \"$1\"", "silta-editor", path.path]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return nil }
      return try read(path.path)
    } catch { throw TaskError.input }
  }

  private struct Printed: Encodable {
    let ref: String
    let status: String
    let document: String
  }
}
