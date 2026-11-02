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
  ]

  @Test(arguments: rows) func matrix(row: Row) {
    let actor = Actor.detect(
      environment: row.environment,
      terminal: TerminalState(stdin: row.stdin, stdout: row.stdout), session: "acme")
    #expect(actor.value == row.expected)
    #expect(actor.isHuman == row.expected.hasPrefix("human:"))
  }

  @Test func humanOnlyRefusalHasHumanNextAndGoldenStreams() throws {
    let actor = Actor.detect(
      environment: [:], terminal: TerminalState(stdin: false, stdout: false), session: "acme")
    do {
      try actor.requireHuman(command: "silta task triage")
      Issue.record("Agent was allowed through a human-only policy")
    } catch let error as ActorError {
      #expect(error.code == .humanOnly)
      #expect(error.exitCode == 3)
      #expect(error.next == ["silta task triage"])
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      Golden.forTests().check(text.stderr + json.stdout, "human-only.txt")
    }
  }

  @Test func humanActorPassesTheSinglePolicyCheck() throws {
    let actor = Actor.detect(
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
      #expect(environment.actor.value == "agent:acme:explicit")
      #expect(!FileManager.default.fileExists(atPath: home.path))
    }
  }
}
