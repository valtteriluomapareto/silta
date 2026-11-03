import ArgumentParser
import Foundation
import SiltaCore

struct TaskEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit task fields; approval is needed unless you hold its claim.",
    discussion: """
      Read task show --json to construct file input. Use five ordered sections:
      ## Title, ## Description, ## Acceptance, ## Plan, ## Result.
      Each heading is followed by a tilde fence (at least ~~~), the literal value,
      then a matching fence on its own line. Choose fences longer than any tilde run
      in the values. Empty fields contain one empty line between fences.
      The editor receives this same document. A changed plan creates a revision.
      """)

  static let dataShape = TaskOutput.receiptShape

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String

  @Option(name: .customShort("F"), help: "Read UTF-8 Markdown from a file, or - for stdin.")
  var file: String?

  @Flag(help: "Retain secrets with human approval.")
  var allowSecret = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let result = try TaskService(
      environment: context.environment, workspace: global.ws,
      approved: global.approved
    ).edit(ref, allowSecret: allowSecret) { original in
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
}
