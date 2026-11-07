import ArgumentParser

struct CommentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Post discussion or change a thread's state.",
    discussion: "The default subcommand is `comment post`; run its help for post options.\n"
      + "Ask: silta comment AC-1 --kind question -m \"Which API?\"\n"
      + "Answer: silta comment AC-1 --kind answer --reply-to AC-1/1 -m \"Use v2.\"\n"
      + "Accept an answer with `comment accept`; replies normalize to their root.\n"
      + "A claimer's handoff releases only that claimer's claim.\n"
      + "See `silta guide questions` for recipient, relay and approval rules.",
    subcommands: [
      CommentPostCommand.self, CommentResolveCommand.self, CommentReopenCommand.self,
      CommentDeleteCommand.self, CommentAcceptCommand.self,
    ], defaultSubcommand: CommentPostCommand.self)

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
