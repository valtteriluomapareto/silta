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
  @Option(help: "comment, question, answer, decision or handoff.") var kind = "comment"
  @Option(help: "A comment in this task; replies join its root thread.") var replyTo: String?
  @Option(name: .customLong("to"), help: "Complete actor or me; repeat for several recipients.")
  var to: [String] = []
  @Option(help: "A note: citation.") var from: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    var draft = CommentDraft(body: "", kind: kind)
    draft.replyTo = replyTo
    draft.to = to
    draft.source = from
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
