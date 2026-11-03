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
      #expect(ticked.stdout.contains("- [x] Ship"))
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
