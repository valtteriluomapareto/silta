import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SeamErrorTests {
  // The harness or the human set these, so an agent can't fix them: they are `env`,
  // with a human as the next step (D34).
  @Test(arguments: [
    ("SILTA_HOME", "bad"), ("SILTA_NOW", "bad"), ("SILTA_ID_SEED", "bad"),
    ("SILTA_ACTOR", "bad"), ("SILTA_SESSION", "b a d"),
  ])
  func invalidOverridesAreCoded(variable: String, value: String) async throws {
    try await withScratchDirectory { scratch in
      do {
        var values = ["SILTA_HOME": scratch.appending(path: "data").path]
        values[variable] = value
        _ = try await SiltaEnvironment.system(
          environment: values, userHome: scratch, temporaryRoots: [], deterministic: true)
        Issue.record("Expected an invalid override error")
      } catch {
        let coded = try #require(error as? any CodedError)
        #expect(coded.code == .env)
        #expect(coded.message.contains(variable))
        #expect(!coded.next.isEmpty)
        #expect(OutputRouter.render(.failure(error), mode: OutputMode(json: true)).exitCode == 9)
      }
    }
  }

  @Test func spawnFailureIsAnActionableEnvironmentError() async throws {
    try await withScratchDirectory { scratch in
      do {
        _ = try await SystemGitRunner(executable: scratch.appending(path: "missing").path)
          .run(GitRequest(arguments: [], directory: scratch))
        Issue.record("Expected a spawn error")
      } catch {
        let coded = try #require(error as? any CodedError)
        #expect(error as? SeamError == .gitUnavailable)
        #expect(coded.code == .env)
        #expect(coded.message.lowercased().contains("git"))
        #expect(!coded.next.isEmpty)
        #expect(
          !OutputRouter.render(.failure(error), mode: OutputMode(json: false)).stderr
            .contains("internal error (bug)"))
      }
    }
  }

  // Process can't start in a missing directory, such as a cwd deleted under the shell.
  @Test func missingDirectoryIsASpawnFailureNotACrash() async throws {
    _ = try await withScratchDirectory { scratch in
      await #expect(throws: SeamError.gitUnavailable) {
        try await SystemGitRunner().run(
          GitRequest(arguments: ["--version"], directory: scratch.appending(path: "gone")))
      }
    }
  }

  @Test func unresolvableHomeIsInvalidRatherThanABug() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "file")
      try Data().write(to: file)
      #expect(throws: SeamError.invalidHome) {
        try SiltaHome.resolve(
          environment: ["SILTA_HOME": file.appending(path: "child").path],
          userHome: scratch)
      }
    }
  }

  @Test func everySeamErrorRendersPerTheContract() {
    var blocks: [String] = []
    for error in SeamError.allCases {
      let text = OutputRouter.render(.failure(error), mode: OutputMode(json: false))
      let json = OutputRouter.render(.failure(error), mode: OutputMode(json: true))
      blocks.append("## \(error) (exit \(text.exitCode))\n\(text.stderr)\(json.stdout)")
    }
    Golden.forTests().check(blocks.joined(separator: "\n"), "seam-errors.txt")
  }
  @Test func existingFileAndItsAliasAreInvalidHomes() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "file")
      let alias = scratch.appending(path: "alias")
      try Data().write(to: file)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
      do {
        for path in [file, alias] {
          #expect(throws: SeamError.invalidHome) {
            try SiltaHome.resolve(environment: ["SILTA_HOME": path.path], userHome: scratch)
          }
        }
      }
    }
  }

}
