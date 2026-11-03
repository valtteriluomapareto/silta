import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskPlanTextTests {
  @Test func planTicksAndImportHaveWrittenTextContracts() throws {
    try withScratchDirectory { scratch in
      _ = try TaskCommandTests.setup(scratch)
      #expect(
        try SiltaBinary.run(
          ["task", "add", "Acme", "--start"], in: scratch,
          environment: TaskCommandTests.actor
        ).termination == .exit(0))
      for (args, golden) in [
        (["task", "plan", "AC-1", "-m", "- [ ] Ship"], "task-plan.txt"),
        (["task", "plan", "AC-1", "--step", "1", "--done"], "task-plan-tick.txt"),
      ] {
        let result = try SiltaBinary.run(args, in: scratch, environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(0))
        Golden.forTests().check(result.stdout, golden)
        #expect(result.stderr.isEmpty)
      }
      let file = scratch.appending(path: "plan.md")
      try "# Acme import\n\nContext\n\n- First\n  Detail\n- Second\n".write(
        to: file, atomically: true, encoding: .utf8)
      let preview = try SiltaBinary.run(
        ["task", "from-plan", file.path, "--split", "--dry-run"], in: scratch,
        environment: TaskCommandTests.actor)
      #expect(preview.termination == .exit(0))
      Golden.forTests().check(preview.stdout, "task-from-plan-preview.txt")
      let imported = try SiltaBinary.run(
        ["task", "from-plan", file.path], in: scratch, environment: TaskCommandTests.actor)
      #expect(imported.termination == .exit(0))
      Golden.forTests().check(imported.stdout, "task-from-plan.txt")
    }
  }
}

extension TaskPlanTextTests {
  @Test func checklistPreviewHasNumberingWithoutChildStatuses() throws {
    try withScratchDirectory { scratch in
      let file = scratch.appending(path: "plan.md")
      try "# Acme\n- First\n".write(to: file, atomically: true, encoding: .utf8)
      let result = try SiltaBinary.run(
        ["task", "from-plan", file.path, "--dry-run"],
        in: scratch, environment: TaskCommandTests.actor)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "task-from-plan-checklist.txt")
    }
  }
}
