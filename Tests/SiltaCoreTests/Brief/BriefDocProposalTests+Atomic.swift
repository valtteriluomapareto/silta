import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

extension BriefDocProposalTests {
  @Test func crowdedTaskKeepsOrOmitsTheWholeMaximumCommandGroup() async throws {
    try await withScratchDirectory { home in
      let (store, service) = try DocInboxIntegrationTests().fixture(home, groups: 1)
      _ = try await InboxGroupTests.add(service, home, "Keep the current Acme task")
      let fixed = "silta --ws 'acme' doc show 'doc:@4' --diff"
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc SET slug=?",
          arguments: [String(repeating: "r", count: 512 - fixed.utf8.count)])
      }
      let preview = try #require(try DocProposalInboxTests().preview(store).first)
      try #require(preview.members.allSatisfy { $0.read.utf8.count == 512 })
      let prefix = "Keep the current task plan.\n."
      try setPlan(prefix, store: store)
      let baseline = try crowdedReport(service, store: store)
      try #require(baseline.sections.last?.text.hasPrefix("doc proposal ") == true)
      let padding = 10_000 - baseline.text.count
      try #require(padding > 512)
      try setPlan(prefix + String(repeating: ".", count: padding), store: store)
      let fitting = try crowdedReport(service, store: store)
      #expect(fitting.text.count == 10_000)
      for command in preview.commands { #expect(fitting.text.contains("next: " + command + "\n")) }
      try setPlan(prefix + String(repeating: ".", count: padding + 1), store: store)
      let omitted = try crowdedReport(service, store: store)
      #expect(omitted.currentTask == "AC-1" && omitted.text.contains("Keep the current Acme task"))
      #expect(omitted.text.contains(prefix) && omitted.text.count <= 10_000 && omitted.truncated)
      #expect(!omitted.text.contains("doc proposal ") && !omitted.text.contains("next: silta"))
      #expect(omitted.text.contains("more: silta --ws 'acme' task show AC-1\n"))
      #expect(omitted.text.contains("more: silta --ws 'acme' inbox\n"))
    }
  }

  private func setPlan(_ body: String, store: DatabaseStore) throws {
    try store.write { try $0.database.execute(sql: "UPDATE task SET plan_md=?", arguments: [body]) }
  }

  private func crowdedReport(_ service: TaskService, store: DatabaseStore) throws -> BriefReport {
    try store.read { db in
      let current = try TaskService.lookup("AC-1", workspace: "acme", in: db)
      return try makeReport(service, budget: 2500, current: current, in: db)
    }
  }
}
