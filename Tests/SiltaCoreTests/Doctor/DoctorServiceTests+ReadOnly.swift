import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

extension DoctorServiceTests {
  @Test func inspectionOnlyRequestsGitVersion() async throws {
    try await withScratchDirectory { home in
      let git = ScriptedGitRunner(script: [
        (
          GitRequest(arguments: ["--version"], directory: URL(filePath: "/")),
          .success(GitResult(termination: .exit(0), stdout: Data("git version 2.50.0\n".utf8)))
        )
      ])
      _ = await DoctorService.inspect(
        store: StorageSchemaTests.store(home), home: home, git: git, at: StorageSchemaTests.instant)
      #expect(git.requests.map(\.arguments) == [["--version"]])
      #expect(git.isExhausted)
    }
  }

}
