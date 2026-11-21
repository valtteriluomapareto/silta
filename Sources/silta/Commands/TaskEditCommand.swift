import ArgumentParser
import Foundation
import SiltaCore

struct TaskEditCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Edit a task (human-only unless you hold its claim or use --print).",
    discussion: "`--print` outputs the document; edit it and return it with `-F`.\n"
      + "Order: ## Title, ## Description, ## Acceptance, ## Plan, ## Result.\n"
      + "Each heading is followed by a tilde fence (~~~ or longer) around the value.\n"
      + "Choose a fence longer than any tilde run in the values.\n"
      + "Empty fields hold one blank line; changed plans make revisions.\n"
      + "Agents can't clear a stored Plan or Result.")

  static let dataShape = Shape.object([
    "ref": .string, "status": .string, "document": .optional(.string),
    "app_change": .optional(
      .object([
        "from": .optional(.string), "to": .optional(.string),
        "children_on_previous_app": .array(.string),
      ])),
  ])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions

  @Argument(help: "The task reference.")
  var ref: String

  @Option(
    name: .customShort("F"),
    help: "Read UTF-8 Markdown from a file, or - for stdin; default is none."
  )
  var file: String?

  @Flag(help: "Print the current document without editing; needs no approval.")
  var print = false

  @Flag(help: "Retain secrets with human approval.")
  var allowSecret = false

  @Option(
    help: .init(
      "Set the primary app, or use none to clear it. Use app:none for a legacy app. "
        + "Use without -F, --print or --allow-secret.")
  )
  var app: String?

  var missingTerminal: Bool { file == nil && !print && !TerminalEditor.hasTerminal }

  static let terminalUsage = UsageError.usage(
    message: "Editing needs terminal input and terminal stderr. Use --print for the current "
      + "document, then supply -F <file> or -F - for stdin.",
    command: "silta task edit")

  func execute(_ context: CommandContext) throws -> CommandOutput {
    if let app { return try move(to: app, context: context) }
    let service = TaskService(
      environment: context.environment, workspace: global.ws, approved: global.approved,
      bodyFlag: file.map { _ in "-F <file>" }, retryBodyFlag: file == "-" ? "-F -" : nil)
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
    guard !missingTerminal else { throw terminalFailure(service) }
    let result = try service.edit(ref, allowSecret: allowSecret) { original in
      if let file { return try BodyInput.read(file) }
      return try edit(original, environment: context.environment)
    }
    return TaskOutput.receipt(
      result.result,
      change: result.result.changed.isEmpty
        ? "unchanged" : "edited: " + result.result.changed.joined(separator: ", "),
      approvalUsed: result.approvalUsed
    ).reporting(context.taskWorkspace(global.ws))
  }

  private func move(to app: String, context: CommandContext) throws -> CommandOutput {
    guard file == nil, !print, !allowSecret else {
      throw TaskError.invalid("Use --app without -F, --print or --allow-secret.")
    }
    let workspace = try context.workspace(global.ws)
    let service = TaskService(
      environment: context.environment, workspace: workspace, approved: global.approved)
    let edited = try service.editApp(ref, to: app)
    var text = "unchanged"
    if let change = edited.result.appChange {
      text = HumanText.line(change.text)
      if !change.childrenOnPreviousApp.isEmpty {
        text +=
          "\nChildren still on " + HumanText.line(change.previous) + ": "
          + change.childrenOnPreviousApp.joined(separator: ", ")
      }
    }
    return TaskOutput.receipt(edited.result, change: text, approvalUsed: edited.approvalUsed)
      .reporting(workspace)
  }

  private func terminalFailure(_ service: TaskService) -> CommandFailure {
    let usage = Self.terminalUsage
    guard let workspace = service.resolvedWorkspace(), WorkspaceConfig.isValidIdentifier(workspace),
      RestoreService.canNameInRecovery(workspace)
    else { return CommandFailure(error: usage, next: usage.next) }
    do {
      let task = try service.show(ref)
      guard RestoreService.canNameInRecovery(task.ref) else {
        return CommandFailure(error: usage, next: usage.next)
      }
      let command = "silta task edit " + shellWord(task.ref) + " --print"
      return CommandFailure(error: usage, next: [workspaceCommand(command, workspace: workspace)])
    } catch {
      return CommandFailure(error: usage, next: usage.next)
    }
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
      guard try TerminalEditor.run(path, command: "silta task edit") == 0 else { return nil }
      return try String(contentsOf: path, encoding: .utf8)
    } catch let error as any CodedError {
      throw error
    } catch { throw TaskError.input }
  }

  private struct Printed: Encodable {
    let ref: String
    let status: String
    let document: String
  }
}
