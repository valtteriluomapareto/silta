import Foundation
import SiltaTestSupport
import Testing

/// `silta schema` from the outside (spec §20.1). Goldens were written from the spec.
struct SchemaCommandTests {
  private func silta(_ arguments: [String]) throws -> CLIResult {
    try withScratchDirectory { try SiltaBinary.run(arguments, in: $0) }
  }

  @Test(arguments: [["schema", "--json"], ["--json", "schema"], ["schema", "schema", "--json"]])
  func jsonListsCommandsArgumentsAndErrors(arguments: [String]) throws {
    let result = try silta(arguments)
    #expect(result.termination == .exit(0))
    #expect(result.stderr.isEmpty)
    Golden.forTests().check(result.stdout, "schema.json")
  }

  @Test func textListsTheSame() throws {
    let result = try silta(["schema"])
    #expect(result.termination == .exit(0))
    #expect(result.stderr.isEmpty)
    Golden.forTests().check(result.stdout, "schema.txt")
  }

  @Test func quietPrintsNothingOnSuccess() throws {
    let result = try silta(["schema", "--quiet"])
    #expect(result == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
  }

  @Test func unknownCommandIsNotFound() throws {
    let text = try silta(["schema", "nope"])
    #expect(text.termination == .exit(2))
    #expect(text.stdout.isEmpty)
    Golden.forTests().check(text.stderr, "schema-unknown-command.txt")
    let json = try silta(["schema", "nope", "--json"])
    #expect(json.termination == .exit(2))
    #expect(json.stderr.isEmpty)
    Golden.forTests().check(json.stdout, "schema-unknown-command.json")
  }

  @Test func unknownFlagOnASubcommandPointsAtItsHelp() throws {
    let text = try silta(["schema", "--nope"])
    #expect(text.termination == .exit(1))
    #expect(text.stdout.isEmpty)
    Golden.forTests().check(text.stderr, "usage-subcommand-unknown-flag.txt")
    let json = try silta(["--json", "schema", "--nope"])
    #expect(json.termination == .exit(1))
    #expect(json.stderr.isEmpty)
    Golden.forTests().check(json.stdout, "usage-subcommand-unknown-flag.json")
  }

  // Every command's data must match the shape `schema` publishes for it.
  @Test func schemaDataMatchesItsOwnPublishedShape() throws {
    let result = try silta(["schema", "--json"])
    let envelope = try #require(
      try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let data = try #require(envelope["data"] as? [String: Any])
    let commands = try #require(data["commands"] as? [[String: Any]])
    let schema = try #require(commands.first { $0["name"] as? String == "silta schema" })
    #expect(ShapeCheck.violations(of: data, against: try #require(schema["data"])) == [])
  }
}
