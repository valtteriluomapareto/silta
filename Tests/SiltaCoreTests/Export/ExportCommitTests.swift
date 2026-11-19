import Darwin
import Foundation
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct ExportCommitTests {
  @Test(arguments: [false, true])
  func exportLockStaysHeldDuringGitCommit(rootIgnored: Bool) async throws {
    try await withScratchDirectory { scratch in
      let home = scratch.appending(path: "home")
      let store = try ExportFixture.make(home)
      let probe = ExportLockProbe(home: home, rootIgnored: rootIgnored)
      let result = try await ExportService.commit(
        workspace: "acme", to: scratch.appending(path: "exports"), store: store, home: home,
        seams: (probe, FakeClock(now: ExportFixture.instant)))
      #expect(result.sha == String(repeating: "1", count: 40))
      let paths = try ExportTreeTests.golden("acme").keys.sorted().map { "acme/" + $0 }
      var expected = [
        ["rev-parse", "--is-inside-work-tree"],
        ["check-ignore", "--"] + paths,
        ["--literal-pathspecs", "add", "-A", "--", "acme"],
      ]
      if rootIgnored {
        expected += [
          ["check-ignore", "--no-index", "--", "acme"],
          ["--literal-pathspecs", "add", "-u", "--", "acme"],
        ]
      }
      expected += [
        ["--literal-pathspecs", "diff", "--cached", "--quiet", "--", "acme"],
        ["--literal-pathspecs", "commit", "-m", "Export acme", "--", "acme"],
        ["rev-parse", "--verify", "HEAD"],
      ]
      let calls = await probe.calls
      #expect(calls == expected)
    }
  }
}

private actor ExportLockProbe: GitRunner {
  let home: URL
  let rootIgnored: Bool
  var calls: [[String]] = []

  init(home: URL, rootIgnored: Bool) {
    self.home = home
    self.rootIgnored = rootIgnored
  }

  func run(_ request: GitRequest) async throws -> GitResult {
    let arguments = request.arguments
    calls.append(arguments)
    switch arguments {
    case ["rev-parse", "--is-inside-work-tree"]:
      return GitResult(termination: .exit(0), stdout: Data("true\n".utf8))
    case ["--literal-pathspecs", "add", "-A", "--", "acme"]:
      return GitResult(termination: .exit(rootIgnored ? 1 : 0))
    case ["check-ignore", "--no-index", "--", "acme"],
      ["--literal-pathspecs", "add", "-u", "--", "acme"]:
      return GitResult(termination: .exit(0))
    case ["--literal-pathspecs", "diff", "--cached", "--quiet", "--", "acme"]:
      return GitResult(termination: .exit(1))
    case ["--literal-pathspecs", "commit", "-m", "Export acme", "--", "acme"]:
      let descriptor = open(home.appending(path: "export.lock").path, O_RDWR)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      let acquired = flock(descriptor, LOCK_EX | LOCK_NB)
      #expect(acquired == -1 && errno == EWOULDBLOCK)
      return GitResult(termination: .exit(0))
    case ["rev-parse", "--verify", "HEAD"]:
      return GitResult(
        termination: .exit(0), stdout: Data((String(repeating: "1", count: 40) + "\n").utf8))
    default:
      if arguments.starts(with: ["check-ignore", "--"]) {
        return GitResult(termination: .exit(1))
      }
      Issue.record("Unexpected Git command")
      return GitResult(termination: .exit(2))
    }
  }
}
