import ArgumentParser

struct CommentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Post discussion or change a thread's state.",
    discussion: """
      Post with: silta comment <task> (-m <text> | -F <file|->) [--kind comment|decision|handoff].
      --allow-secret retains secrets with human approval. A handoff names state,
      next step, open questions and branch/sha, and releases only its author's claim.
      """,
    subcommands: [
      CommentPostCommand.self, CommentResolveCommand.self, CommentReopenCommand.self,
      CommentDeleteCommand.self,
    ], defaultSubcommand: CommentPostCommand.self)

  @OptionGroup var global: GlobalOptions
}
