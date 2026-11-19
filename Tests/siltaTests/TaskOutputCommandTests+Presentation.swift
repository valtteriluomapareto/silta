import Foundation
import SiltaTestSupport
import Testing

extension TaskOutputCommandTests {
  @Test func storedTaskAndCommentControlsStayOutOfHumanText() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let environment = TaskCommandTests.fixed.merging(["USER": "acme"]) { _, new in new }
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: environment)
      }
      let description = "Acme café\u{1b}one\u{7}two\tvalue\nline two\u{d}tail"
      let comment = "Acme question\u{1b}one\u{7}two\n\tkeep café"
      try #require(
        run(["task", "add", "Acme rendering", "--start", "-m", description])
          .termination == .exit(0))
      try #require(
        run(["comment", "AC-1", "--kind", "question", "--to", "me", "-m", comment]).termination
          == .exit(0))
      for flags in [[], ["--quiet"]] {
        let text = try run(["task", "show", "AC-1"] + flags)
        #expect(text.termination == .exit(0) && text.stderr.isEmpty)
        withKnownIssue("#254: stored text rendering") {
          Golden.forTests().check(text.stdout, "task-show-terminal-text.txt")
        }
        let inbox = try run(["inbox", "--for", "me"] + flags)
        #expect(inbox.termination == .exit(0) && inbox.stderr.isEmpty)
        withKnownIssue("#254: stored text rendering") {
          #expect(inbox.stdout.contains("> Acme question one two\n> \tkeep café\n"))
        }
        withKnownIssue("#254: stored text rendering") {
          #expect(!inbox.stdout.contains("\u{1b}") && !inbox.stdout.contains("\u{7}"))
        }
      }
      let detail = try TaskStateRegressionTests.data(run(["task", "show", "AC-1", "--json"]))
      #expect(detail["description"] as? String == description)
      let posts = try #require(detail["comments"] as? [[String: Any]])
      #expect(posts.first?["body"] as? String == comment)
      let printed = try run(["task", "edit", "AC-1", "--print"])
      #expect(printed.termination == .exit(0) && printed.stdout.contains(description))
    }
  }
}
