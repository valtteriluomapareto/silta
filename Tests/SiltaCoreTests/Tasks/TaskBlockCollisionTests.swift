import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct TaskBlockCollisionTests {
  @Test func conflictingSecondLinkUIDRollsBackWholeBlock() async throws {
    try await withScratchDirectory { home in
      let service = try TaskOrganizationTests.service(home)
      try await TaskBlockTests.add(service, count: 2, directory: home)
      let seed = TaskServiceTests.agent.description.utf8.reduce(0) { $0 + UInt64($1) }
      let oracle = SeededIDGenerator(seed: seed)
      for _ in 0..<3 { _ = try oracle.next(at: TaskServiceTests.now) }
      let collision = try oracle.next(at: TaskServiceTests.now)
      try service.environment.db.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_ext,
            created_by,created_at)
            VALUES(?,1,'task',2,'cites','url','https://example.com/acme',?,?)
            """,
          arguments: [
            collision, TaskServiceTests.agent.description,
            TaskService.timestamp(TaskServiceTests.now),
          ])
      }
      let before = try TaskOrganizationTests.counts(service)
      #expect(throws: StorageError.unavailable) {
        _ = try service.block("AC-1", TaskBlockTests.input(["ext:acme", "AC-2"]))
      }
      #expect(try TaskOrganizationTests.counts(service) == before)
      let task = try service.show("AC-1")
      #expect(task.status == "doing" && task.followUpAt == nil && task.links.isEmpty)
      #expect(task.claimedBy == TaskServiceTests.agent.description)
    }
  }
}
