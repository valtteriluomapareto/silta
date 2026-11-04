import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Testing

struct CommentDiscoveryTests {
  @Test func olderHandoffRepliesRemainDiscoverable() async throws {
    try await withScratchDirectory { home in
      let env = try await CommentTests.setup(home)
      try env.db.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO comment(id,uid,task_id,seq,kind,body_md,actor,created_at) VALUES
            (1,'h1',1,1,'handoff','Earlier context','agent:codex:acme','t'),
            (2,'h2',1,2,'handoff','Latest context','agent:codex:acme','t');
            INSERT INTO comment(uid,task_id,seq,thread_id,kind,body_md,actor,created_at)
            VALUES('reply',1,3,1,'comment','Reviewer finding','agent:claude:reviewer','t');
            """)
      }
      let service = TaskService(environment: env)
      let shown = try #require(service.show("AC-1").comments)
      withKnownIssue("#13: A new handoff must not hide unresolved discussion on an older one") {
        #expect(shown.map(\.ref) == ["AC-1/2", "AC-1/1", "AC-1/3"])
        #expect(shown.contains { $0.body == "Reviewer finding" })
      }
      #expect(try service.show("AC-1", timeline: true).comments?.count == 3)
    }
  }
}
