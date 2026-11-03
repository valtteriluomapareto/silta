import ArgumentParser
import Foundation
import SiltaCore

struct TaskEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit task fields; approval is needed unless you hold its claim.",
    discussion: """
      --print prints the current document; change it and pass it back with -F.
      It has five ordered sections: ## Title, ## Description, ## Acceptance, ## Plan,
      ## Result. Each heading is followed by a tilde fence (at least ~~~), the literal
      value, then a matching fence on its own line. Choose fences longer than any tilde
      run in the values. Empty fields contain one empty line between fences.
      The editor receives this same document. A changed plan creates a revision.
      Agents can't clear a stored Result or Plan.
      """)

  static let dataShape = Shape.object([
    "ref": .string, "status": .string, "document": .optional(.string),
  ])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String

  @Option(name: .customShort("F"), help: "Read UTF-8 Markdown from a file, or - for stdin.")
  var file: String?

  @Flag(help: "Print the current edit document without editing; needs no approval.")
  var print = false

  @Flag(help: "Retain secrets with human approval.")
  var allowSecret = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let service = TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved)
    if print {
      guard file == nil, !allowSecret else {
        throw TaskError.invalid("--print only reads; use it without -F or --allow-secret.")
      }
      let printed = try service.editDocument(ref)
      return CommandOutput(
        text: printed.document,
        data: Printed(
          ref: printed.task.ref, status: printed.task.status, document: printed.document))
    }
    let result = try service.edit(ref, allowSecret: allowSecret) { original in
      if let file { return try read(file) }
      return try edit(original, environment: context.environment)
    }
    return TaskOutput.receipt(result.result, approvalUsed: result.approvalUsed)
      .reporting(context.taskWorkspace(global.ws))
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
