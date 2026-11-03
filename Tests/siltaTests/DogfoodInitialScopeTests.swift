import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DogfoodInitialScopeTests {
  @Test func firstWorkspaceEditLogsItsProducedIdentityWithoutCurrentSelection() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "workspace.yaml")
      try Data("workspace: {slug: beta, name: Acme Beta, task_prefix: BE}\n".utf8).write(to: file)
      let result = try DogfoodScopeBoundaryTests.run(
        [
          "ws", "edit", "-F", file.path,
          "--approved", "Set up this Acme workspace",
        ], scratch: scratch)
      #expect(result.termination == .exit(0))
      let entry = try DogfoodScopeBoundaryTests.last(scratch)
      #expect(entry["workspace"] as? String == "beta")
    }
  }

  @Test func absentStorageAttributionDoesNotInitializeDatabase() throws {
    try withScratchDirectory { scratch in
      let result = try DogfoodScopeBoundaryTests.run(["task", "show", "AC-1"], scratch: scratch)
      #expect(result.termination == .exit(2))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
      let entry = try DogfoodScopeBoundaryTests.last(scratch)
      #expect(entry["workspace"] == nil && entry["app"] == nil)
    }
  }
}
