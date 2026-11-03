import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)), .tags(.slow), .enabled(if: slowTestsEnabled()))
struct ScenarioExpectationTests {
  @Test func scalarExpectationsRejectMissingPathsAndTypeMismatches() throws {
    try withScratchDirectory { scratch in
      for (index, pair) in [
        ("schema: 1", true), ("schema: '1'", false),
        ("data.missing: 1", false), ("schema: 2", false),
      ].enumerated() {
        let (expectation, passes) = pair
        let file = scratch.appending(path: "scalar-\(index).yaml")
        try Data(
          "steps:\n  - args: [schema, --json]\n    expect: {exit: 0, json: {\(expectation)}}\n".utf8
        ).write(to: file)
        let evidence = scratch.appending(path: "evidence-\(index)")
        if passes {
          _ = try ScenarioRunner.run(file, in: scratch, evidence: evidence)
        } else {
          #expect(throws: ScenarioFailure.self) {
            try ScenarioRunner.run(file, in: scratch, evidence: evidence)
          }
        }
      }
    }
  }

  // Each matcher must be able to fail; a misspelled key must not silently skip one (§20.1).
  @Test(arguments: [
    "{exit: 1, code: not_found}", "{exit: 1, stdout: schema.txt}", "{exit: 1, cdoe: invalid}",
  ])
  func wrongExpectationsAndUnknownKeysFail(expectation: String) throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "wrong.yaml")
      try Data(
        "steps:\n  - args: [schema, nope, --json]\n    expect: \(expectation)\n".utf8
      ).write(to: file)
      #expect(throws: ScenarioFailure.self) {
        try ScenarioRunner.run(file, in: scratch, evidence: scratch.appending(path: "evidence"))
      }
    }
  }

  @Test(arguments: [
    "fixture: true\nsteps: []\n",
    "steps:\n  - args: []\n    enviroment: {}\n    expect: {exit: 0}\n",
  ])
  func unknownScenarioKeysFail(yaml: String) throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "typo.yaml")
      try Data(yaml.utf8).write(to: file)
      #expect(throws: ScenarioFailure.self) {
        try ScenarioRunner.run(file, in: scratch, evidence: scratch.appending(path: "evidence"))
      }
    }
  }

  @Test func transcriptKeepsStderr() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "stderr.yaml")
      try Data("steps:\n  - args: [schema, nope]\n    expect: {exit: 1}\n".utf8).write(to: file)
      let transcript = try ScenarioRunner.run(file, in: scratch)
      let entry = try #require(JSONSerialization.jsonObject(with: transcript) as? [String: Any])
      #expect((entry["stderr"] as? String)?.hasPrefix("error: ") == true)
    }
  }

  @Test func transcriptIncludesActorAndSessionWithoutArbitraryEnvironmentValues() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "identifiers.yaml")
      try Data(
        """
        steps:
          - args: [--version]
            env: {SILTA_ACTOR: 'agent:acme:review', SILTA_SESSION: acme, ACME_PRIVATE: 'Acme note'}
            expect: {exit: 0}
        """.utf8
      ).write(to: file)
      let transcript = try ScenarioRunner.run(file, in: scratch)
      let entry = try #require(JSONSerialization.jsonObject(with: transcript) as? [String: Any])

      #expect(entry["actor"] as? String == "agent:acme:review")
      #expect(entry["session"] as? String == "acme")
      let text = try #require(String(bytes: transcript, encoding: .utf8))
      #expect(!text.contains("Acme note"))
      #expect(!text.contains("ACME_PRIVATE"))
    }
  }
}
