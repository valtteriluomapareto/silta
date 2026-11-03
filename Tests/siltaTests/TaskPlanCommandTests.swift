import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskPlanCommandTests {
  @Test func revisionsTicksAndImportHaveWrittenContracts() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let added = try SiltaBinary.run(
        ["task", "add", "Acme plan", "--start"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(added.termination == .exit(0))
      let planned = try SiltaBinary.run(
        ["task", "plan", "AC-1", "-m", "- [ ] Ship", "--if-rev", "0", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(planned.termination == .exit(0))
      Golden.forTests().check(planned.stdout, "task-plan.json")
      let ticked = try SiltaBinary.run(
        ["task", "plan", "AC-1", "--step", "1", "--done", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(ticked.termination == .exit(0))
      Golden.forTests().check(ticked.stdout, "task-plan-tick.json")
      let staleTick = try SiltaBinary.run(
        ["task", "plan", "AC-1", "--step", "1", "--undo", "--if-rev", "0", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(staleTick.termination == .exit(6))
      #expect(staleTick.stdout.contains("stale_rev"))
      let stale = try SiltaBinary.run(
        ["--ws", "acme", "task", "plan", "AC-1", "-m", "New", "--if-rev", "0", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(stale.termination == .exit(6))
      Golden.forTests().check(stale.stdout, "task-plan-stale.json")
      let file = scratch.appending(path: "plan.md")
      try "# Acme import\n\nContext\n\n- First\n  Detail\n- Second\n".write(
        to: file, atomically: true, encoding: .utf8)
      let imported = try SiltaBinary.run(
        ["task", "from-plan", file.path, "--json"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(imported.termination == .exit(0))
      Golden.forTests().check(imported.stdout, "task-from-plan.json")
    }
  }
}

extension TaskPlanCommandTests {
  @Test func previewConflictsAndAgentOverrideHaveNoSideEffects() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "plan.md")
      try "# Acme\n\n- First\n".write(to: file, atomically: true, encoding: .utf8)
      let preview = try SiltaBinary.run(
        ["task", "from-plan", file.path, "--split", "--dry-run", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(preview.termination == .exit(0))
      #expect(preview.stdout.contains("\"tasks\":[]"))
      #expect(preview.stdout.contains("\"dry_run\":true"))
      let override = try SiltaBinary.run(
        ["--ws", "acme", "task", "from-plan", "/absent", "--allow-secret", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(override.termination == .exit(3))
      #expect(override.stdout.contains("silta --ws 'acme' task from-plan <file> --allow-secret"))
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      #expect(
        try SiltaBinary.run(
          ["task", "plan", "AC-1", "-m", "- [ ] Step"], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      for args in [
        ["plan", "AC-1"], ["plan", "AC-1", "--done"], ["plan", "AC-1", "--done", "-m", "Body"],
        ["plan", "AC-1", "--step", "1", "--done", "-F", "/absent"],
        ["plan", "AC-1", "--step", "1"],
        ["plan", "AC-1", "--step", "1", "--done", "--undo"],
        ["plan", "AC-1", "--step", "1", "--done", "-m", "Body"],
        ["from-plan", file.path, "--dry-run", "--delete"],
      ] {
        let result = try SiltaBinary.run(
          ["task"] + args + ["--json"], in: scratch,
          environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("--help"))
      }
      #expect(FileManager.default.fileExists(atPath: file.path))
    }
  }

  @Test func localUntrackedDeleteHappensOnlyAfterSuccessfulImport() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      let repo = scratch.appending(path: "work", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      #expect(
        try SiltaBinary.runProcess(
          URL(filePath: "/usr/bin/git"), ["init", "-q"], in: scratch, cwd: repo
        ).termination == .exit(0))
      let file = repo.appending(path: "plan.md")
      try "# Acme\n\n- First\n".write(to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        ["task", "from-plan", file.path, "--delete", "--json"], in: scratch, cwd: repo,
        environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("AC-1"))
      #expect(!FileManager.default.fileExists(atPath: file.path))
      try "# Tracked\n\n- Preserve\n".write(to: file, atomically: true, encoding: .utf8)
      #expect(
        try SiltaBinary.runProcess(
          URL(filePath: "/usr/bin/git"), ["add", "plan.md"], in: scratch, cwd: repo
        ).termination == .exit(0))
      let tracked = try SiltaBinary.run(
        ["task", "from-plan", file.path, "--delete", "--json"], in: scratch, cwd: repo,
        environment: TaskCommandTests.actor)
      #expect(tracked.termination == .exit(1))
      #expect(FileManager.default.fileExists(atPath: file.path))
      let list = try SiltaBinary.run(
        ["task", "ls", "--json"], in: scratch, environment: TaskCommandTests.actor)
      #expect(!list.stdout.contains("AC-2"))
    }
  }
}

extension TaskPlanCommandTests {
  @Test func importReadsStdinAndReportsInputFailuresWithoutCreatingStorage() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "plan.md")
      try "# Acme\n\n- First\n".write(to: file, atomically: true, encoding: .utf8)
      for source in ["", "-"] {
        let command = "exec \"$1\" task from-plan " + source + " --dry-run --json < \"$2\""
        let preview = try SiltaBinary.runProcess(
          URL(filePath: "/bin/sh"), ["-c", command, "_", try SiltaBinary.url().path, file.path],
          in: scratch, environment: TaskCommandTests.actor)
        #expect(preview.termination == .exit(0))
        #expect(preview.stdout.contains("\"tasks\":[]"))
      }
      try Data([255]).write(to: file)
      for source in [file.path, file.path + "-absent"] {
        let failed = try SiltaBinary.run(
          ["task", "from-plan", source, "--dry-run", "--json"], in: scratch,
          environment: TaskCommandTests.actor)
        #expect(failed.termination == .exit(1))
        #expect(failed.stdout.contains("\"code\":\"invalid\""))
      }
      #expect(
        !FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path)
      )
    }
  }
}

extension TaskPlanCommandTests {
  @Test func binaryNumbersOnlyTopLevelBoxesOutsideFences() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      let text = "```md\r\n- [ ] Example\r\n```\r\n- [X] Å\r\n  - [ ] Nested\r\n2. [ ] β"
      let file = scratch.appending(path: "plan.md")
      try text.write(to: file, atomically: true, encoding: .utf8)
      #expect(
        try SiltaBinary.run(
          ["task", "plan", "AC-1", "-F", file.path], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      let tick = try SiltaBinary.run(
        ["task", "plan", "AC-1", "--step", "2", "--done", "--if-rev", "1", "--json"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(tick.termination == .exit(0))
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(tick.stdout.utf8)) as? [String: Any])
      let data = try #require(object["data"] as? [String: Any])
      #expect(data["plan_rev"] as? Int == 1)
      #expect(data["step"] as? Int == 2 && data["title"] as? String == "β")
      #expect(data["steps"] as? Int == 2 && data["steps_done"] as? Int == 2)
      let shown = try SiltaBinary.run(
        ["task", "show", "AC-1", "--json"], in: scratch, environment: TaskCommandTests.actor)
      let detail = try #require(
        JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any])
      let plan = try #require((detail["data"] as? [String: Any])?["plan"] as? String)
      #expect(
        Array(plan.utf8) == Array(text.replacingOccurrences(of: "2. [ ] β", with: "2. [x] β").utf8))
      let help = try SiltaBinary.run(["task", "plan", "--help"], in: scratch)
      let words = help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      #expect(words.contains("checked entries count"))
      #expect(words.contains("fenced examples do not"))
    }
  }
}
