import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct BriefDocProposalTests {
  @Test(arguments: [(0, 0), (1024, 0), (1200, 1), (2500, 2), (10_000, 3)])
  func budgetHydratesOnlyRetainedGroups(example: (Int, Int)) throws {
    try withScratchDirectory { home in
      let (store, service) = try DocInboxIntegrationTests().fixture(home, groups: 4)
      let before = try DocVerificationPreparationTests.truth(store)
      try store.read { db in
        var sql: [String] = []
        db.trace { if case .statement(let statement) = $0 { sql.append(statement.expandedSQL) } }
        let report = try makeReport(service, budget: example.0, in: db)
        db.trace(nil)
        let kept = report.sections.filter { $0.text.hasPrefix("doc proposal ") }
        #expect(kept.count == example.1)
        let windows = sql.filter { $0.contains("WITH eligible AS") }
        #expect(windows.count == (example.1 == 0 ? 0 : 1))
        #expect(
          try windows.map { try Row.fetchAll(db, sql: $0).count }.reduce(0, +) == example.1 * 2)
        if example.0 >= 1024 {
          #expect(report.text.count <= example.0 * 4)
          #expect(report.text.contains("inbox: 4 items for human:acme"))
        }
        #expect(report.text.contains("more: silta --ws 'acme' inbox"))
        #expect(!report.text.contains(String(repeating: " ", count: 100)))
        let json = try #require(
          try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let sections = try #require(json["sections"] as? [[String: Any]])
        #expect(sections.allSatisfy { Set($0.keys) == ["id", "text"] })
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
    }
  }

  @Test func hydrationKeepsTheMetadataSnapshot() throws {
    try withScratchDirectory { home in
      let (store, service) = try DocInboxIntegrationTests().fixture(home, groups: 1)
      var changed = false
      var writeError: (any Error)?
      let report = try store.read { db in
        db.trace {
          guard case .statement(let statement) = $0,
            statement.sql.contains("ORDER BY newest DESC"), !changed
          else { return }
          changed = true
          do {
            try store.write {
              try $0.database.execute(
                sql: "UPDATE doc_rev SET message='Newly committed why' WHERE state='proposed'")
            }
          } catch { writeError = error }
        }
        defer { db.trace(nil) }
        return try makeReport(service, budget: 10_000, in: db)
      }
      #expect(changed && writeError == nil)
      #expect(
        report.text.contains("A complete why") && !report.text.contains("Newly committed why"))
      #expect(
        try store.read {
          try Int.fetchOne(
            $0, sql: "SELECT count(*) FROM doc_rev WHERE message='Newly committed why'")
        } == 3)
    }
  }

  @Test(arguments: [false, true])
  func rendererKeepsEvidenceAndUsesOnlySelectedCommands(unsafe: Bool) throws {
    try withScratchDirectory { home in
      let (store, _) = try DocInboxIntegrationTests().fixture(home, groups: 1)
      let fixed = "silta --ws 'acme' doc show 'doc:@4' --diff"
      let length = unsafe ? 600 : 512 - fixed.utf8.count
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET slug=?", arguments: [String(repeating: "r", count: length)])
        try $0.database.execute(
          sql: """
            UPDATE workspace SET task_prefix=?;
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            SELECT 'source',id,1,'Acme source','doing','human:acme','','' FROM workspace;
            UPDATE doc_rev SET source_task_id=(SELECT id FROM task),about_refs='[]'
              WHERE state='proposed';
            """, arguments: [String(repeating: "S", count: 118)])
        try $0.database.execute(
          sql: "UPDATE doc_rev SET title=?,kind=?,message=? WHERE state='proposed'",
          arguments: [
            String(repeating: "t", count: 120), String(repeating: "k", count: 120),
            String(repeating: "w", count: 120),
          ])
      }
      let group = try #require(try DocProposalInboxTests().preview(store).first)
      let next = Array(Set(group.members.map(\.read) + [try #require(group.next)])).sorted()
      try #require(next.count == (unsafe ? 1 : 3))
      if !unsafe { #expect(group.members.allSatisfy { $0.read.utf8.count == 512 }) }
      let complete = group.render(next: next)
      #expect(complete.hasPrefix("doc proposal ") && complete.count <= 4096)
      #expect(complete.components(separatedBy: "> ref: ").count == 3)
      for member in group.members { #expect(complete.contains(member.ref)) }
      for command in next { #expect(complete.components(separatedBy: command).count == 2) }
      let omitted = group.render(next: [])
      #expect(!omitted.contains("next:") && omitted.contains(group.members[0].why))
      let selected = group.render(next: [next[0]])
      #expect(selected.components(separatedBy: next[0]).count == 2)
      for command in next.dropFirst() { #expect(!selected.contains(command)) }
    }
  }

  @Test func retainedGroupsDeduplicateProtectedHubsWithoutDroppingEvidence() throws {
    try withScratchDirectory { home in
      let (store, service) = try DocInboxIntegrationTests().fixture(home, groups: 2)
      try store.write {
        for (slug, suffix) in [("rules", "A"), ("rules1", "B")] {
          try $0.database.execute(
            sql: "UPDATE doc SET slug=? WHERE slug=?",
            arguments: ["AKIA" + String(repeating: suffix, count: 16), slug])
        }
      }
      let report = try store.read { try makeReport(service, budget: 10_000, in: $0) }
      #expect(report.sections.filter { $0.text.hasPrefix("doc proposal ") }.count == 2)
      #expect(report.text.components(separatedBy: "> ref: ").count == 5)
      #expect(
        report.text.components(separatedBy: "next: silta --ws 'acme' doc ls --archived").count == 2)
      #expect(!report.text.contains("AKIA"))
    }
  }

  private func makeReport(_ service: TaskService, budget: Int, in db: Database) throws
    -> BriefReport
  {
    let location = LocationResult(
      path: "/acme", worktree: "/acme", workspace: "acme", repo: "platform", branch: "main",
      head: "a", confidence: "high", reason: "single", candidates: [])
    return try BriefService(environment: service.environment).report(
      location, budget: budget, at: AcmeDocAttachments.instant, in: db)
  }
}
