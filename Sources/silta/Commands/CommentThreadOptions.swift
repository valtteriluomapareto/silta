import ArgumentParser
import SiltaCore

/// Shared inputs and execution for the two thread state commands.
struct CommentThreadOptions: ParsableArguments {
  @OptionGroup var body: TaskBody
  @Argument(
    help: "Thread refs; -m creates one reply per changed thread. Replies select their root.")
  var refs: [String]

  func execute(_ context: CommandContext, global: GlobalOptions, action: CommentAction) throws
    -> CommandOutput
  {
    let workspace = try context.workspace(global.ws)
    let explanation = try body.readContent(command: action.command(refs, workspace: workspace))
    let result = try TaskService(
      environment: context.environment, workspace: workspace,
      approved: global.approved, bodyFlag: body.flag
    ).updateComments(refs, action: action, explanation: explanation, allowSecret: body.allowSecret)
    return CommentOutput.mutation(result).reporting(workspace)
  }
}
