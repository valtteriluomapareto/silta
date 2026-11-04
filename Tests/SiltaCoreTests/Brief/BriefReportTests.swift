import Foundation
@testable import SiltaCore
import Testing

struct BriefReportTests {
  @Test func manyCandidateRetriesRemainBudgetedBeforeTask() throws {
    let location = LocationResult(
      path: "/acme", worktree: "/acme", workspace: "acme",
      repo: "platform", branch: nil, head: "a", confidence: "low", reason: "distance",
      candidates: [])
    let sections = (1...100).map { index in
      BriefSection(
        id: "candidates",
        text: "candidates: app\(index) (origin/main)\n"
          + "next: silta --ws 'acme' brief --app 'app\(index)'\n")
    }
    var report = BriefReport(
      location: BriefLocation(location),
      settings: BriefSettings(
        WorkspaceSettings(workspace: "acme", json: "{\"proposals\":\"ask\"}"), workspace: "acme"),
      currentTask: nil, sections: sections, more: ["silta --ws 'acme' ws show"], warnings: [])
    report.trim(tokens: 200)
    #expect(report.text.count <= 800)
    #expect(report.truncated)
    #expect(!report.text.contains("app100"))
    let candidate = try #require(report.text.range(of: "candidates:"))
    let task = try #require(report.text.range(of: "task: none"))
    #expect(candidate.lowerBound < task.lowerBound)
    #expect(
      report.text.contains("settings: proposals: ask (ask in chat before adding a task)\ntask:"))
    let json = try #require(String(bytes: try JSONEncoder().encode(report), encoding: .utf8))
    #expect(!json.contains("app100"))
    #expect(report.more.count == 1)
    #expect(json.contains("\"app\":null"))
    #expect(json.contains("\"branch\":null"))
  }
}
