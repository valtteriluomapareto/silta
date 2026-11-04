import ArgumentParser
import SiltaCore

struct CommentCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Post task discussion; a claimer's handoff releases its claim.")
  static let dataShape = CommentOutput.shape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @OptionGroup var body: TaskBody
  @Argument(help: "The task reference.") var target: String
  @Option(help: "comment, decision or handoff.") var kind = "comment"
  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    var draft = CommentDraft(body: "", kind: kind)
    draft.allowSecret = body.allowSecret
    let command = TaskService.commentCommand(target, draft, workspace: workspace)
    draft.body =
      try body.read(actor: context.environment.actor, command: command, approved: global.approved)
      ?? ""
    let result = try TaskService(
      environment: context.environment, workspace: workspace, approved: global.approved,
      bodyFlag: body.flag
    ).comment(target, draft)
    return CommandOutput(
      text: result.comment.ref + " " + result.comment.kind, quiet: result.comment.ref,
      data: result.comment, warnings: result.warnings, approvalUsed: result.approvalUsed
    ).reporting(workspace)
  }
}
