import ArgumentParser

/// Flags every command accepts, before or after the subcommand (spec §16).
struct GlobalOptions: ParsableArguments {
  @Option(help: "Use this workspace instead of repository location or the saved default.")
  var ws: String?

  @Option(parsing: .unconditional, help: "The human's words approving this command in chat.")
  var approved: String?

  @Flag(help: "Print the JSON envelope on stdout instead of text.")
  var json = false

  @Flag(help: "Hide success text; warnings and errors still show.")
  var quiet = false

  @Flag(help: "Allow deterministic overrides outside temporary homes; never at the real home.")
  var deterministic = false

  @Flag(help: "Mirror command diagnostics to stderr.")
  var verbose = false
}
