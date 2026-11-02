import SiltaCore
import Testing

/// The schema's text and JSON layout (spec §20.1) for cases the one real command
/// doesn't exercise: several commands, options, required and help-less arguments.
struct SchemaDocumentTests {
  static let commands = [
    CommandSchema(
      name: "silta task ls", abstract: "List tasks.",
      arguments: [
        ArgumentSchema(
          kind: "option", names: ["-a", "--app"], required: true, repeating: false,
          valueName: "slug", help: "Only this app."),
        ArgumentSchema(
          kind: "positional", names: ["<ref>"], required: true, repeating: true,
          valueName: "ref", help: nil),
      ],
      data: .object(["ids": .array(.string)])),
    CommandSchema(
      name: "silta where", abstract: "Show the app here.", arguments: [], data: .bool),
  ]
  static let global = [
    ArgumentSchema(
      kind: "flag", names: ["--json"], required: false, repeating: false, valueName: nil,
      help: "JSON.")
  ]

  @Test func detailText() {
    let document = SchemaDocument(commands: Self.commands, globalArguments: Self.global)
    #expect(
      document.detailText.hasPrefix(
        """
        silta task ls
          List tasks.
          -a, --app <slug>  required: Only this app.
          <ref>  required, repeating
          --json data: {"object":{"ids":{"array":"string"}}}

        silta where
          Show the app here.
          --json data: "bool"

        global flags:
          --json  optional: JSON.

        error codes:
          usage  exit 1, next by agent: Read `silta <cmd> --help` and fix the call

        """))
  }

  @Test func indexTextAndJSON() throws {
    let index = SchemaDocument(commands: Self.commands, globalArguments: Self.global).index
    #expect(
      index.indexText.hasPrefix(
        """
        silta task ls  List tasks.
        silta where  Show the app here.
        details: silta schema <command>

        global flags:

        """))
    let rendered = OutputRouter.render(
      .success(CommandOutput(text: "", data: index)), mode: OutputMode(json: true))
    #expect(
      rendered.stdout.hasPrefix(
        #"{"data":{"commands":[{"abstract":"List tasks.","name":"silta task ls"},"#
          + #"{"abstract":"Show the app here.","name":"silta where"}],"errors":[{"#))
  }
}
