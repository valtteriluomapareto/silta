import Foundation
import GRDB
import SiltaTestSupport
import Synchronization
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocProposalSelectionTests {
  @Test(arguments: ["current", "prepared", "none", "failure"])
  func selectionIsResolvedAfterInputAndPreparedOutcomesStayAuthoritative(kind: String) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      var environment = try DocProposalServiceTests.service(home, store).environment
      if kind == "prepared" { environment.workspaceSelection = .success("acme") }
      if kind == "none" { environment.workspaceSelection = .success(nil) }
      if kind == "failure" { environment.workspaceSelection = .failure(StorageError.accessDenied) }
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO meta(key,value) VALUES('current_workspace','missing')
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
      }
      let service = DocProposalService(environment: environment, workspace: nil, approved: nil)
      var read = false
      var committed: [[String]] = []
      var failure: (any CodedError)?
      var result: DocProposalResult?
      do {
        result = try service.propose(DocProposalServiceTests.request()) {
          read = true
          try store.write {
            try $0.database.execute(
              sql: "UPDATE meta SET value=? WHERE key='current_workspace'",
              arguments: [kind == "prepared" ? "missing" : "acme"])
          }
          committed = try DocVerificationPreparationTests.truth(store)
          return "Body"
        }
      } catch let error as any CodedError { failure = error }
      #expect(read)
      if kind == "current" || kind == "prepared" {
        #expect(failure == nil && result?.workspace == "acme" && result?.ref == "doc:rules@1")
      } else {
        #expect(result == nil)
        #expect(failure?.code == (kind == "none" ? .notFound : .env))
        #expect(try DocVerificationPreparationTests.truth(store) == committed)
      }
    }
  }

  @Test func rawBusyReplayResolvesCurrentWorkspaceAgain() throws {
    try withScratchDirectory { home in
      let seed = try AcmeDocAttachments.make(in: home)
      try seed.write {
        try $0.database.execute(
          sql: """
            INSERT INTO workspace(id,uid,slug,name,task_prefix)
            VALUES(2,'beta','beta','Beta','BE');
            INSERT INTO service(uid,workspace_id,slug,name) VALUES('beta-push',2,'push','Push');
            INSERT INTO meta(key,value) VALUES('current_workspace','acme')
            ON CONFLICT(key) DO UPDATE SET value=excluded.value;
            """)
      }
      let external = try DatabaseQueue(path: seed.path)
      let retries = Mutex(0)
      let clock = FakeClock(now: AcmeDocAttachments.instant)
      let store = DatabaseStore(
        home: URL(filePath: seed.path).deletingLastPathComponent(), clock: clock,
        jitter: {
          retries.withLock { $0 += 1 }
          do {
            try external.write {
              try $0.execute(sql: "UPDATE meta SET value='beta' WHERE key='current_workspace'")
            }
          } catch { Issue.record(error) }
          return 0
        })
      let base = try DocProposalServiceTests.service(home, seed).environment
      let environment = SiltaEnvironment(
        clock: clock, ids: BusyOnceProposalIDs(), git: base.git, home: base.home,
        db: store, log: base.log, actor: base.actor)
      var reads = 0
      let result = try DocProposalService(environment: environment).propose(
        DocProposalServiceTests.request()
      ) {
        reads += 1
        return "Body"
      }
      #expect(reads == 1 && retries.withLock { $0 } == 1)
      #expect(result.workspace == "beta")
      #expect(
        try store.read {
          try String.fetchOne(
            $0,
            sql: """
              SELECT w.slug FROM doc d JOIN workspace w ON w.id=d.workspace_id
              """)
        } == "beta")
      #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc") } == 1)
    }
  }

}

private final class BusyOnceProposalIDs: IDGenerator {
  private let calls = Mutex(0)
  private let base = SeededIDGenerator(seed: 94)

  func next(at timestamp: Date) throws -> String {
    if calls.withLock({
      $0 += 1
      return $0
    }) == 1 {
      throw DatabaseError(resultCode: .SQLITE_BUSY)
    }
    return try base.next(at: timestamp)
  }
}
