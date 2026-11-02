import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)), .tags(.slow), .enabled(if: slowTestsEnabled()))
struct FixtureIsolationTests {
  @Test func fixtureSymlinkCannotRedirectGenerationOutsideScratch() throws {
    try withScratchDirectory { outside in
      try withScratchDirectory { scratch in
        try FileManager.default.createSymbolicLink(
          at: scratch.appending(path: "fixtures"), withDestinationURL: outside)
        let file = scratch.appending(path: "fixture-escape.yaml")
        try Data("fixtures: true\nsteps: []\n".utf8).write(to: file)
        let evidence = scratch.appending(path: "evidence")

        #expect(throws: ScenarioFailure.self) {
          try ScenarioRunner.run(file, in: scratch, evidence: evidence)
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        #expect(contents.isEmpty)
      }
    }
  }
}
