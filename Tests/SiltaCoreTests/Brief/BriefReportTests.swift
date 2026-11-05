import Foundation
@testable import SiltaCore
import Testing

struct BriefReportTests {}

extension BriefReportTests {
  @Test func planTrimProgressDoesNotDependOnSectionName() {
    let location = LocationResult(
      path: "/acme", worktree: "/acme", workspace: "acme",
      repo: "platform", branch: nil, head: "a", confidence: "high", reason: "single", candidates: []
    )
    var report = BriefReport(
      location: BriefLocation(location),
      settings: BriefSettings(WorkspaceSettings(workspace: "acme", json: "{}"), workspace: "acme"),
      currentTask: "AC-1",
      sections: [
        BriefSection(
          id: "renamed-plan",
          text: "plan:\n1. [ ] first\n2. [ ] " + String(repeating: "long ", count: 100),
          policy: .plan(ref: "AC-1", total: 2))
      ],
      more: ["silta --ws 'acme' task show AC-1"], warnings: [])
    report.trim(tokens: 65)
    #expect(report.text.contains("(plan trimmed: 1/2;"))
  }
}

extension BriefReportTests {
  @Test func markerBudgetBoundaries() {
    let location = LocationResult(
      path: "/acme", worktree: "/acme", workspace: "acme",
      repo: "platform", branch: "main", head: "a", confidence: "high", reason: "single",
      candidates: [])
    for budget in 0...200 {
      let plan = BriefPlan.section(
        (1...60).map { "- [ ] Acme step \($0)" }.joined(separator: "\n"), ref: "AC-1", revision: 0)
      var report = BriefReport(
        location: BriefLocation(location),
        settings: BriefSettings(
          WorkspaceSettings(workspace: "acme", json: "{}"), workspace: "acme"),
        currentTask: "AC-1", sections: [plan], more: ["silta task show AC-1"], warnings: [])
      let marker = [0, 60].map {
        BriefPlan.marker(ref: "AC-1", total: 60, through: $0, workspace: "acme").count
      }.max() ?? 0
      let minimum = report.floor.count + report.footer.count + marker
      report.trim(tokens: budget)
      #expect(report.text.count <= max(budget * 4, minimum), "budget \(budget)")
    }
    var complete = BriefReport(
      location: BriefLocation(location),
      settings: BriefSettings(WorkspaceSettings(workspace: "acme", json: "{}"), workspace: "acme"),
      currentTask: "AC-1",
      sections: [
        BriefPlan.section("- [ ] first", ref: "AC-1", revision: 0),
        BriefSection(id: "later", text: String(repeating: "x", count: 1000)),
      ],
      more: ["silta task show AC-1"], warnings: [])
    complete.trim(tokens: 100)
    #expect(complete.text.contains("(brief trimmed; see more)"))
    #expect(!complete.text.contains("plan trimmed"))
  }
}
