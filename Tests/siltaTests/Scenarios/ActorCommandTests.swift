import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(3)), .tags(.slow), .enabled(if: slowTestsEnabled()))
struct ActorCommandTests {
  @Test func scenarioLogsExactActorAndSessionHandover() throws {
    try withScratchDirectory { scratch in
      let file = ScenarioRunner.repository.appending(path: "Tests/Scenarios/actor-handover.yaml")
      _ = try ScenarioRunner.run(file, in: scratch)
      let logs = try String(
        contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
      let actors = try logs.split(separator: "\n").map { line in
        let entry = try #require(
          JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try #require(entry["actor"] as? String)
      }
      #expect(actors == ["agent:acme:first", "agent:codex:handover", "agent:claude:review"])
    }
  }
}
