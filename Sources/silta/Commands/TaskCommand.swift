import ArgumentParser

struct TaskCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "task", abstract: "Keep task work, plans and results in the local backlog.",
    subcommands: [
      TaskAddCommand.self, TaskListCommand.self, TaskShowCommand.self,
      TaskStartCommand.self, TaskSubmitCommand.self, TaskDoneCommand.self, TaskDropCommand.self,
    ])

  @OptionGroup var global: GlobalOptions
}
