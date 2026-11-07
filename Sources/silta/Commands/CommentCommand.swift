import ArgumentParser

struct CommentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comment",
    abstract: "Post task discussion; a claimer's handoff releases its claim.",
    discussion: "The default subcommand is `comment post`; see `silta comment post --help`.\n"
      + "Ask: silta comment AC-1 --kind question -m \"Which API?\"\n"
      + "Answer: silta comment AC-1 --kind answer --reply-to AC-1/1 -m \"Use v2.\"\n"
      + "Accept (asker or current claimer): silta comment accept AC-1/2.\n"
      + "Post findings as roots; replies normalize to their root.\n"
      + "A claimer's handoff releases its claim; see `silta guide questions`.",
    subcommands: [
      CommentPostCommand.self, CommentResolveCommand.self, CommentReopenCommand.self,
      CommentDeleteCommand.self, CommentAcceptCommand.self,
    ], defaultSubcommand: CommentPostCommand.self)

  @OptionGroup(title: "Global Options") var global: GlobalOptions
}
