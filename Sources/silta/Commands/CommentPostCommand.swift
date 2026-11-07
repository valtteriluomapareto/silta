import ArgumentParser
import SiltaCore

struct CommentPostCommand: OutputCommand {
  static let configuration = CommandConfiguration(
    commandName: "post",
    abstract: "Post task discussion; a claimer's handoff releases its claim.",
    shouldDisplay: false)
  static let dataShape = CommentOutput.receiptShape
  static let workspaceSource = WorkspaceSource.option

  @OptionGroup(title: "Global Options") var global: GlobalOptions
  @OptionGroup var body: TaskBody
  @Argument(help: "The task reference.") var target: String
  @Option(
    help: .init(
      "One of \(CommentDraft.kinds.joined(separator: ", ")); default is comment. "
        + "A handoff names state, next step, open questions and branch/sha.")
  )
  var kind: String?
  @Option(help: "Join this post's thread; replies normalize to its root; default is none.")
  var replyTo: String?
  @Option(
    name: .customLong("to"),
    help: .init(
      "Recipient: complete actor or me; repeatable, default none. "
        + "Questions default to the human; @me means human:<USER>."))
  var recipients: [String] = []
  @Option(name: .customLong("from"), help: "Cite a note: reference; default is none.")
  var source: String?

  func execute(_ context: CommandContext) throws -> CommandOutput {
    let workspace = try context.workspace(global.ws)
    var draft = CommentDraft(body: "", kind: kind)
    draft.allowSecret = body.allowSecret
    draft.replyTo = replyTo
    draft.recipients = recipients
    draft.source = source
    let command = TaskService.commentCommand(target, draft, workspace: workspace)
    draft.body =
      try body.read(actor: context.environment.actor, command: command, approved: global.approved)
      ?? ""
    let result = try TaskService(
      environment: context.environment, workspace: workspace, approved: global.approved,
      bodyFlag: body.flag
    ).comment(target, draft, includeWorkspaceInAudit: global.ws != nil)
    return CommandOutput(
      text: result.comment.ref + " " + result.comment.kind
        + (result.released ? "; claim released" : ""), quiet: result.comment.ref,
      data: result, warnings: result.warnings, approvalUsed: result.approvalUsed
    ).reporting(workspace)
  }
}
