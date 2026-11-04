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
    let location = LocationResult(path: "/acme", worktree: "/acme", workspace: "acme",
      repo: "platform", branch: "main", head: "a", confidence: "high", reason: "single", candidates: [])
    for budget in 60...120 {
      let plan = BriefPlan.section("- [ ] first\n- [ ] " + String(repeating: "long ", count: 80), ref: "AC-1", revision: 0)
      var report = BriefReport(location: BriefLocation(location),
        settings: BriefSettings(WorkspaceSettings(workspace: "acme", json: "{}"), workspace: "acme"),
        currentTask: "AC-1", sections: [plan], more: ["silta task show AC-1"], warnings: [])
      report.trim(tokens: budget)
      #expect(report.text.count <= budget * 4)
    }
    var complete = BriefReport(location: BriefLocation(location),
      settings: BriefSettings(WorkspaceSettings(workspace: "acme", json: "{}"), workspace: "acme"),
      currentTask: "AC-1", sections: [BriefPlan.section("- [ ] first", ref: "AC-1", revision: 0),
        BriefSection(id: "later", text: String(repeating: "x", count: 1000))],
      more: ["silta task show AC-1"], warnings: [])
    complete.trim(tokens: 100)
    #expect(complete.text.contains("(brief trimmed; see more)"))
    #expect(!complete.text.contains("plan trimmed"))
  }
}
