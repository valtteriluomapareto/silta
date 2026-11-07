import ArgumentParser

/// Flags every command accepts, before or after the subcommand (spec §16).
struct GlobalOptions: ParsableArguments {
  @Option(help: "Use this workspace; default is inferred or saved.")
  var ws: String?

  @Option(
    parsing: .unconditional,
    help: "The human's words approving this command in chat; default is none.")
  var approved: String?

  @Flag(help: "Print JSON; default is text.")
  var json = false

  @Flag(help: "Hide success text; warnings and errors still show.")
  var quiet = false

  @Flag(help: .hidden)
  var deterministic = false

  @Flag(help: "Mirror command diagnostics to stderr.")
  var verbose = false
}
