import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskFutureFieldTests {
  @Test func organizationWritersPreserveNondefaultFutureFields() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      _ = try await TaskOrganizationTests.add(service, directory: home)
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: """
            ALTER TABLE task ADD COLUMN future TEXT DEFAULT 'Acme default';
            UPDATE task SET future='Acme retained';
            UPDATE workspace SET settings='{"future":"Acme retained"}';
            """)
      }
      var batch = TaskTriage()
      batch.accept = ["AC-1"]
      _ = try service.triage(batch)
      try Self.check(service)
      _ = try service.edit("AC-1") { $0.replacingOccurrences(of: "Acme", with: "Acme edited") }
      try Self.check(service)
      _ = try service.archive("AC-1")
      try Self.check(service)
      _ = try service.archive("AC-1", keep: true)
      try Self.check(service)
      _ = try service.link("AC-1", target: "url:https://example.com/acme")
      try Self.check(service)
      _ = try service.promote("AC-1", external: "ado:42")
      try Self.check(service)
    }
  }

  private static func check(_ service: TaskService) throws {
    try service.environment.db.read { db in
      let task = try String.fetchOne(db, sql: "SELECT future FROM task")
      let settings = try String.fetchOne(db, sql: "SELECT settings FROM workspace")
      #expect(task == "Acme retained")
      #expect(settings == "{\"future\":\"Acme retained\"}")
    }
  }
}
