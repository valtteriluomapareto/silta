import ArgumentParser

struct TaskCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "task", abstract: "Keep task work, plans and results in the local backlog.",
    subcommands: [
      TaskAddCommand.self, TaskListCommand.self, TaskShowCommand.self,
      TaskStartCommand.self, TaskSubmitCommand.self, TaskDoneCommand.self, TaskDropCommand.self,
      TaskPlanCommand.self, TaskFromPlanCommand.self,
      TaskEditCommand.self, TaskTriageCommand.self, TaskArchiveCommand.self,
      TaskKeepCommand.self, TaskLinkCommand.self, TaskPromoteCommand.self,
    ])

  @OptionGroup var global: GlobalOptions
}
