import ArgumentParser

/// Flags every command accepts, before or after the subcommand (spec §16).
struct GlobalOptions: ParsableArguments {
  @Flag(help: "Print the JSON envelope on stdout instead of text.")
  var json = false

  @Flag(help: "Hide success text; warnings and errors still show.")
  var quiet = false
}
