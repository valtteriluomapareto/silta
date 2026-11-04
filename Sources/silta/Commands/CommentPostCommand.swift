import ArgumentParser
import SiltaCore

struct CommentPostCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "post",
    abstract: "Post task discussion; a claimer's handoff releases its claim.",
    shouldDisplay: false)
  static let dataShape = CommentOutput.receiptShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup var global: GlobalOptions
  @OptionGroup var body: TaskBody
  @Argument(help: "The task reference.") var target: String
  @Option(
    help: .init(
      "comment, decision or handoff. "
        + "A handoff names state, next step, open questions and branch/sha.")
  )
  var kind = "comment"
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
      text: result.comment.ref + " " + result.comment.kind
        + (result.released ? "; claim released" : ""), quiet: result.comment.ref,
      data: result, warnings: result.warnings, approvalUsed: result.approvalUsed
    ).reporting(workspace)
  }
}
