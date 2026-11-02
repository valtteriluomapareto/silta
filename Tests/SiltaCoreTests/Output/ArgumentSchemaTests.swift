import ArgumentParser
import SiltaCore
import Testing

/// Pins how ArgumentParser's dump-help JSON becomes schema arguments (D31), for every
/// kind of argument a command may declare. An ArgumentParser upgrade that changes
/// the dump fails here.
struct ArgumentSchemaTests {
  struct Fixture: ParsableArguments {
    @Option(name: .shortAndLong, help: "The app.") var app: String
    @Option(help: "Tags.") var tag: [String] = []
    @Flag(inversion: .prefixedNo, help: "Colour.") var color = true
    @Flag(name: .customLong("verbose", withSingleDash: true)) var verbose = false
    @Argument(help: "Refs.") var refs: [String] = []
    @Option(help: .hidden) var secret: String?
  }

  @Test func everyKindOfArgument() throws {
    let arguments = try ArgumentSchema.list(dumpedHelp: Fixture._dumpHelp())
    #expect(
      arguments == [
        ArgumentSchema(
          kind: "option", names: ["--app", "-a"], required: true, repeating: false,
          valueName: "app", help: "The app."),
        ArgumentSchema(
          kind: "option", names: ["--tag"], required: false, repeating: true,
          valueName: "tag", help: "Tags."),
        // An inversion is two flags sharing one help text.
        ArgumentSchema(
          kind: "flag", names: ["--color"], required: false, repeating: false,
          valueName: nil, help: "Colour."),
        ArgumentSchema(
          kind: "flag", names: ["--no-color"], required: false, repeating: false,
          valueName: nil, help: "Colour."),
        ArgumentSchema(
          kind: "flag", names: ["-verbose"], required: false, repeating: false,
          valueName: nil, help: nil),
        ArgumentSchema(
          kind: "positional", names: ["<refs>"], required: false, repeating: true,
          valueName: "refs", help: "Refs."),
      ])
  }
}
