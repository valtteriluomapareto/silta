import ArgumentParser

struct CommentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Post discussion or change a thread's state.",
    discussion: """
      Post with: silta comment <task> (-m <text> | -F <file|->)
        [--kind comment|question|answer|decision|handoff].
      Ask: silta comment AC-1 --kind question -m "Which API?"
      Answer: silta comment AC-1 --kind answer --reply-to AC-1/1 -m "Use v2."
      Accept (asker or current claimer): silta comment accept AC-1/2
      An agent's relayed answer never supplies approval words. After confirming the human's
      answer, the claimer accepts the relay or the relayer resolves with -m explaining it.
      @me and --to me mean human:<USER>, independent of the caller; questions default to me.
      Code spans/fences are examples, not mentions. Tool-only --to agent:codex is refused.
      Replies normalize to the thread root. Questions and handoffs are roots.
      Post findings as roots, not replies to a handoff: the newest handoff thread stays shown.
      --allow-secret retains secrets with human approval. A handoff names state,
      next step, open questions and branch/sha, and releases only its author's claim.
      """,
    subcommands: [
      CommentPostCommand.self, CommentResolveCommand.self, CommentReopenCommand.self,
      CommentDeleteCommand.self, CommentAcceptCommand.self,
    ], defaultSubcommand: CommentPostCommand.self)

  @OptionGroup var global: GlobalOptions
}
