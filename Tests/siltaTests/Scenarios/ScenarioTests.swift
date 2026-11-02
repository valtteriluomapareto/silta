import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(5)), .tags(.slow), .enabled(if: slowTestsEnabled()))
struct ScenarioTests {
  @Test func allScenariosReplayByteIdentically() throws {
    let root = ScenarioRunner.repository.appending(path: "Tests/Scenarios")
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "yaml" }.sorted { $0.path < $1.path }
    try #require(!files.isEmpty)
    for file in files {
      var transcripts: [Data] = []
      for _ in 0..<2 {
        try withScratchDirectory { scratch in
          transcripts.append(try ScenarioRunner.run(file, in: scratch))
        }
      }
      #expect(transcripts[0] == transcripts[1])
    }
  }

  @Test func stepEnvironmentsProduceDistinctReplayableFirstIDs() throws {
    try withScratchDirectory { scratch in
      var runs: [[String]] = []
      for _ in 0..<2 {
        let values = try (0..<2).map { index in
          let values = ScenarioRunner.environment(step: index, overrides: [:], scratch: scratch)
          let environment = try SiltaEnvironment.system(environment: values, userHome: scratch,
            temporaryRoots: [scratch])
          return try environment.ids.next(at: environment.clock.now())
        }
        #expect(values[0] != values[1])
        runs.append(values)
      }
      #expect(runs[0] == runs[1])
    }
  }

  @Test func wrongExpectationAndMalformedYAMLLeaveFailureEvidence() throws {
    try withScratchDirectory { scratch in
      for (name, contents) in [
        ("wrong", "steps:\n  - args: [--version]\n    expect: {exit: 99}\n"),
        ("malformed", "steps: ["),
      ] {
        let file = scratch.appending(path: name + ".yaml")
        try Data(contents.utf8).write(to: file)
        let evidence = scratch.appending(path: "evidence-" + name)
        #expect(throws: ScenarioFailure.self) { try ScenarioRunner.run(file, in: scratch, evidence: evidence) }
        #expect(FileManager.default.fileExists(atPath: evidence.appending(path: "failure.md").path))
        #expect(FileManager.default.fileExists(atPath: evidence.appending(path: "transcript.ndjson").path))
        let summary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: evidence.appending(path: "summary.json"))) as? [String: Any])
        #expect(summary["passed"] as? Bool == false)
        #expect((summary["scenario_sha256"] as? String)?.count == 64)
      }
    }
  }

  @Test func environmentOverridesCannotEscapeIsolationOrChangeStepIdentity() throws {
    try withScratchDirectory { scratch in
      let expected = ScenarioRunner.environment(step: 1, overrides: [:], scratch: scratch)
      let actual = ScenarioRunner.environment(step: 1, overrides: [
        "HOME": "/acme-outside", "SILTA_HOME": "/acme-outside", "SILTA_NOW": "bad", "SILTA_ID_SEED": "bad",
      ], scratch: scratch)
      #expect(actual == expected)
      let outside = scratch.deletingLastPathComponent()
      let alias = scratch.appending(path: "escape")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
      for relative in ["../", "escape", outside.path] {
        #expect(throws: ScenarioFailure.self) { try ScenarioRunner.workingDirectory(relative, scratch: scratch) }
      }
    }
  }

  @Test func nonExitTerminationsCannotSatisfyAnExitExpectation() {
    for termination in [Termination.timedOut, .signal(9)] {
      #expect(ScenarioRunner.terminationMismatch(termination, expected: 0) != nil)
    }
  }
}
