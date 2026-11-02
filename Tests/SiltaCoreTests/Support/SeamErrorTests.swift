import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SeamErrorTests {
  @Test(arguments: ["SILTA_HOME", "SILTA_NOW", "SILTA_ID_SEED"])
  func invalidOverridesAreCoded(variable: String) throws {
    try withScratchDirectory { scratch in
      withKnownIssue("#3: expected seam input errors are not CodedError") {
        do {
          var values = ["SILTA_HOME": scratch.appending(path: "data").path]
          values[variable] = "bad"
          _ = try SiltaEnvironment.system(environment: values, userHome: scratch, deterministic: true)
          Issue.record("Expected an invalid override error")
        } catch {
          let coded = try #require(error as? any CodedError)
          #expect(coded.code == .invalid)
          #expect(coded.message.contains(variable))
          #expect(!coded.next.isEmpty)
          #expect(OutputRouter.render(.failure(error), mode: OutputMode(json: true)).exitCode == 1)
        }
      }
    }
  }

  @Test func spawnFailureIsAnActionableEnvironmentError() async throws {
    try await withScratchDirectory { scratch in
      await withKnownIssue("#3: spawn failure escapes as an uncoded Foundation error") {
        do {
          _ = try await SystemGitRunner(executable: scratch.appending(path: "missing").path)
            .run(GitRequest(arguments: [], directory: scratch))
          Issue.record("Expected a spawn error")
        } catch {
          let coded = try #require(error as? any CodedError)
          #expect(coded.code == .env)
          #expect(coded.message.lowercased().contains("git"))
          #expect(!coded.next.isEmpty)
          #expect(!OutputRouter.render(.failure(error), mode: OutputMode(json: false)).stderr
            .contains("internal error (bug)"))
        }
      }
    }
  }
}
