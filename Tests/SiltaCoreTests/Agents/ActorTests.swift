import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ActorTests {
  struct Row: Sendable {
    var environment: [String: String]
    var stdin: Bool
    var stdout: Bool
    var expected: String
  }

  // OPENCODE_ACME_TEST is synthetic; the real OpenCode marker remains unverified.
  static let rows: [Row] = [
    Row(
      environment: ["CODEX_THREAD_ID": ""], stdin: true, stdout: true,
      expected: "agent:codex:acme"),
    Row(
      environment: ["SILTA_ACTOR": "agent:acme:explicit", "CLAUDECODE": "1"], stdin: true,
      stdout: true, expected: "agent:acme:explicit"),
    Row(
      environment: ["SILTA_ACTOR": "human:acme"], stdin: true, stdout: false, expected: "human:acme"
    ),
    Row(
      environment: ["SILTA_ACTOR": "human:acme", "CLAUDECODE": "1"], stdin: false, stdout: true,
      expected: "agent:claude:acme"),
    Row(
      environment: ["SILTA_ACTOR": "human:acme"], stdin: false, stdout: false,
      expected: "agent:unknown:acme"),
    Row(
      environment: ["CLAUDECODE": "1", "CODEX_THREAD_ID": "acme", "OPENCODE_ACME_TEST": "1"],
      stdin: true, stdout: true, expected: "agent:claude:acme"),
    Row(
      environment: ["CODEX_THREAD_ID": "acme", "OPENCODE_ACME_TEST": "1"], stdin: true,
      stdout: true, expected: "agent:codex:acme"),
    Row(
      environment: ["OPENCODE_ACME_TEST": "1"], stdin: true, stdout: true,
      expected: "agent:opencode:acme"),
    Row(environment: [:], stdin: false, stdout: true, expected: "agent:unknown:acme"),
    Row(environment: [:], stdin: true, stdout: false, expected: "agent:unknown:acme"),
    Row(environment: [:], stdin: false, stdout: false, expected: "agent:unknown:acme"),
    Row(
      environment: ["USER": "acme", "CLAUDECODE": "0"], stdin: true, stdout: true,
      expected: "human:acme"),
    Row(environment: [:], stdin: true, stdout: true, expected: "human:unknown"),
    // D9: an explicit agent without a session gets the resolved one.
    Row(
      environment: ["SILTA_ACTOR": "agent:acme"], stdin: false, stdout: false,
      expected: "agent:acme:acme"),
    // Empty values count as unset; a USER that can't be recorded is unknown.
    Row(
      environment: ["SILTA_ACTOR": ""], stdin: false, stdout: false,
      expected: "agent:unknown:acme"),
    Row(environment: ["USER": "acme user"], stdin: true, stdout: true, expected: "human:unknown"),
    Row(
      environment: ["USER": String(repeating: "a", count: 65)], stdin: true, stdout: true,
      expected: "human:unknown"),
    Row(
      environment: ["SILTA_ACTOR": "agent:acme:" + String(repeating: "s", count: 64)],
      stdin: false, stdout: false, expected: "agent:acme:" + String(repeating: "s", count: 64)),
  ]

  @Test(arguments: rows) func matrix(row: Row) throws {
    let actor = try ActorID.detect(
      environment: row.environment,
      terminal: TerminalState(stdin: row.stdin, stdout: row.stdout), session: "acme")
    #expect(actor.description == row.expected)
    #expect(actor.isHuman == row.expected.hasPrefix("human:"))
  }

  // Actors are recorded on every write, so a malformed one never gets that far.
  @Test(arguments: [
    "acme", "agent:", "human:", "agent:acme:", "agent:a:b:c", "robot:acme", "agent:acme:has space",
    "human:acme;rm", "agent:Claude", "human:acme.", "human:a@b", "agent:acme:-x",
    "human:" + String(repeating: "a", count: 65), "human:a:b", "human:ä",
  ])
  func malformedExplicitActorIsRefused(value: String) {
    #expect(throws: SeamError.invalidActor) {
      try ActorID.detect(
        environment: ["SILTA_ACTOR": value], terminal: TerminalState(stdin: true, stdout: true),
        session: "acme")
    }
  }

  @Test func humanOnlyRefusalHasHumanNextAndGoldenStreams() throws {
    let actor = try ActorID.detect(
      environment: [:], terminal: TerminalState(stdin: false, stdout: false), session: "acme")
    do {
      try actor.requireHuman(command: "silta task triage")
      Issue.record("Agent was allowed through a human-only policy")
    } catch let error as ActorError {
      #expect(error.code == .humanOnly)
      #expect(error.exitCode == 3)
      #expect(error.next == ["silta task triage --approved \"<the human's words>\""])
      #expect(error.message.contains("agent:unknown:acme"))
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      Golden.forTests().check(text.stderr + json.stdout, "human-only.txt")
    }
  }

  @Test func humanActorPassesTheSinglePolicyCheck() throws {
    let actor = try ActorID.detect(
      environment: ["USER": "acme"], terminal: TerminalState(stdin: true, stdout: true),
      session: "acme")
    try actor.requireHuman(command: "silta task triage")
  }
  @Test func environmentCarriesTheResolvedActorWithoutOpeningHome() async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "data")
      let environment = try await SiltaEnvironment.system(
        environment: [
          "SILTA_HOME": home.path, "SILTA_ACTOR": "agent:acme:explicit",
        ], userHome: scratch)
      #expect(environment.actor.description == "agent:acme:explicit")
      #expect(!FileManager.default.fileExists(atPath: home.path))
    }
  }
}
