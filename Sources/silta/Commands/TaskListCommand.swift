import ArgumentParser
import SiltaCore

struct TaskListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List workspace tasks, including your own proposals.")

  static let dataShape = Shape.object(["tasks": .array(TaskOutput.detailShape)])

  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions

  @Option(help: "Show this status.") var status: String?

  @Option(help: "Show this app.") var app: String?

  var appSlug: String? { app }

  @Option(help: "Show tasks blocked on this task, ext:party or URL.") var on: String?

  @Option(help: "Show this topic.") var topic: String?

  @Flag(help: "Show tasks created or claimed by this exact actor.") var mine = false

  @Flag(help: "Include other actors' proposals.") var proposed = false

  @Flag(help: "Include archived tasks.") var archived = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var filter = TaskFilter()
    filter.status = status
    filter.on = on
    filter.app = app
    filter.topic = topic
    filter.mine = mine
    filter.proposed = proposed
    filter.archived = archived
    let tasks = try TaskService(environment: context.environment, workspace: global.ws).list(filter)
    return CommandOutput(
      text: tasks.isEmpty ? "No tasks." : tasks.map(TaskOutput.summary).joined(separator: "\n"),
      data: Data(tasks: tasks)
    ).reporting(context.taskWorkspace(global.ws))
  }

  private struct Data: Encodable {
    let tasks: [TaskDetails]
  }
}
