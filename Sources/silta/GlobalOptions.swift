import ArgumentParser

/// Flags every command accepts, before or after the subcommand (spec §16).
struct GlobalOptions: ParsableArguments {
  @Option(help: "Use a workspace; default is inferred or saved.")
  var ws: String?

  @Option(parsing: .unconditional, help: "The human's chat approval; default is none.")
  var approved: String?

  @Flag(help: "Print JSON; default is text.")
  var json = false

  @Flag(help: "Hide success text; default is off.")
  var quiet = false

  @Flag(help: .hidden)
  var deterministic = false

  @Flag(help: "Mirror diagnostics; default is off.")
  var verbose = false
}
