import ArgumentParser
import SiltaCore

struct TaskListCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List workspace tasks, including your own proposals.")

  static let dataShape = Shape.object(["tasks": .array(TaskOutput.summaryShape)])

  @OptionGroup var global: GlobalOptions

  @Option(help: "Show this status.") var status: String?

  @Option(help: "Show this app.") var app: String?

  @Option(help: "Show tasks blocked on this task, ext:party or URL.") var on: String?

  @Option(help: "Show this topic.") var topic: String?

  @Flag(help: "Show tasks created or claimed by this exact actor.") var mine = false

  @Flag(help: "Include other actors' proposals; --status proposed implies it.")
  var proposed = false

  @Flag(help: "Include tasks promoted to a tracker.") var promoted = false

  @Flag(help: "Include archived tasks.") var archived = false

  func execute(_ context: CommandContext) throws -> CommandOutput {
    var filter = TaskFilter()
    filter.status = status
    filter.on = on
    filter.app = app
    filter.topic = topic
    filter.mine = mine
    filter.proposed = proposed
    filter.promoted = promoted
    filter.archived = archived
    let tasks = try TaskService(environment: context.environment, workspace: global.ws).list(filter)
    let text = tasks.isEmpty ? "No tasks." : tasks.map(TaskOutput.summary).joined(separator: "\n")
    return CommandOutput(text: text, quiet: text, data: Data(tasks: tasks.map(TaskSummary.init)))
  }

  private struct Data: Encodable {
    let tasks: [TaskSummary]
  }
}

/// The fields of `TaskOutput.summaryShape`; bodies come from `task show`. Links are
/// short and masked as in `show`, and they find a task by its issue URL.
private struct TaskSummary: Encodable {
  let ref: String
  let title: String
  let status: String
  let priority: Int
  let app: String?
  let parent: String?
  let claimedBy: String?
  let claimedAt: String?
  let externalRef: String?
  let waiting: TaskWaiting?
  let followUpAt: String?
  let createdBy: String
  let createdAt: String
  let updatedAt: String
  let archived: Bool
  let links: [TaskLink]

  init(_ task: TaskDetails) {
    ref = task.ref
    title = task.title
    status = task.status
    priority = task.priority
    app = task.app
    parent = task.parent
    claimedBy = task.claimedBy
    claimedAt = task.claimedAt
    externalRef = task.externalRef
    waiting = task.waiting
    followUpAt = task.followUpAt
    createdBy = task.createdBy
    createdAt = task.createdAt
    updatedAt = task.updatedAt
    archived = task.archived
    links = task.links
  }

  enum CodingKeys: String, CodingKey {
    case ref, title, status, priority, app, parent, waiting, archived, links
    case claimedBy = "claimed_by"
    case claimedAt = "claimed_at"
    case externalRef = "external_ref"
    case followUpAt = "follow_up_at"
    case createdBy = "created_by"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}
