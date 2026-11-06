import Darwin
import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct ExportCommitTests {
  @Test func exportLockStaysHeldDuringGitCommit() async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let result = try await ExportService.commit(
        workspace: "acme", to: scratch.appending(path: "exports"), store: store, home: home,
        seams: (ExportLockProbe(home: home), FakeClock(now: ExportFixture.instant)))
      #expect(result.sha == String(repeating: "1", count: 40))
    }
  }
}

private struct ExportLockProbe: GitRunner {
  let home: URL

  func run(_ request: GitRequest) async throws -> GitResult {
    if request.arguments == ["rev-parse", "--is-inside-work-tree"] {
      return GitResult(termination: .exit(0), stdout: Data("true\n".utf8))
    }
    if request.arguments.first == "check-ignore" { return GitResult(termination: .exit(1)) }
    if request.arguments.first == "diff" { return GitResult(termination: .exit(1)) }
    if request.arguments.first == "commit" {
      let descriptor = open(home.appending(path: "export.lock").path, O_RDWR)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      let acquired = flock(descriptor, LOCK_EX | LOCK_NB)
      #expect(acquired == -1 && errno == EWOULDBLOCK)
    }
    return GitResult(
      termination: .exit(0), stdout: Data((String(repeating: "1", count: 40) + "\n").utf8))
  }
}
