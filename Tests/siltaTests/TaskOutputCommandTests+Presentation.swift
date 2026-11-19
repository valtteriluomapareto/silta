import Foundation
import GRDB
import SiltaCore
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
      let description = "Acme cafe\u{301}\u{1b}one\u{7}two\tvalue\nline two\u{d}tail"
      let comment = "Acme question\u{1b}one\u{7}two\n\tkeep cafe\u{301}"
      try #require(
        run(["task", "add", "Acme rendering", "--start", "-m", description])
          .termination == .exit(0))
      try #require(
        run(["comment", "AC-1", "--kind", "question", "--to", "me", "-m", comment]).termination
          == .exit(0))
      for flags in [[], ["--quiet"]] {
        let text = try run(["task", "show", "AC-1"] + flags)
        #expect(text.termination == .exit(0) && text.stderr.isEmpty)
        Golden.forTests().check(text.stdout, "task-show-terminal-text.txt")
        let inbox = try run(["inbox", "--for", "me"] + flags)
        #expect(inbox.termination == .exit(0) && inbox.stderr.isEmpty)
        #expect(inbox.stdout.contains("> Acme question one two\n> \tkeep cafe\u{301}\n"))
        #expect(!inbox.stdout.contains("\u{1b}") && !inbox.stdout.contains("\u{7}"))
      }
      let detail = try TaskStateRegressionTests.data(run(["task", "show", "AC-1", "--json"]))
      let storedDescription = try #require(detail["description"] as? String)
      #expect(storedDescription.utf8.elementsEqual(description.utf8))
      let posts = try #require(detail["comments"] as? [[String: Any]])
      let storedComment = try #require(posts.first?["body"] as? String)
      #expect(storedComment.utf8.elementsEqual(comment.utf8))
      let printed = try run(["task", "edit", "AC-1", "--print"])
      #expect(printed.termination == .exit(0) && printed.stdout.contains(description))
    }
  }

  @Test func storedInlineAndHistoricalTextKeepsItsFrame() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.fixed)
      }
      try #require(run(["task", "add", "Acme", "--start"]).termination == .exit(0))
      let plan = "- [ ] Acme\u{1b}step\u{7}label"
      try #require(run(["task", "plan", "AC-1", "-m", plan]).termination == .exit(0))
      let ticked = try run(["task", "plan", "AC-1", "--step", "1", "--done"])
      #expect(ticked.stdout == "AC-1 step 1 done: Acme step label (1/1)\n")
      let reason = "Acme\u{1b}wait\u{7}reason\nmore"
      let blocked = try run(["task", "block", "AC-1", "--on", "ext:acme", "-m", reason])
      #expect(blocked.termination == .exit(0))
      #expect(blocked.stdout.contains("ask ext:acme: Acme wait reason more\n"))
      let rawTitle = "Acme\u{1b}title\u{7}label"
      try store.write {
        try $0.database.execute(sql: "UPDATE task SET title=?", arguments: [rawTitle])
        try $0.database.execute(
          sql: """
            INSERT INTO task_event(task_id,actor,kind,body,created_at)
            VALUES(1,'agent:codex:acme','discussion',?,'2023-11-14T22:13:20.000Z')
            """, arguments: ["Acme\u{1b}event\u{7}body"])
      }
      let list = try run(["task", "ls"])
      #expect(list.termination == .exit(0))
      #expect(list.stdout.contains("Acme title label\n"))
      #expect(list.stdout.contains("Acme wait reason more\n"))
      let timeline = try run(["task", "show", "AC-1", "--timeline"])
      #expect(timeline.termination == .exit(0))
      #expect(timeline.stdout.contains("discussion: Acme event body\n"))
      #expect(!timeline.stdout.contains("\u{1b}") && !timeline.stdout.contains("\u{7}"))
    }
  }

}
