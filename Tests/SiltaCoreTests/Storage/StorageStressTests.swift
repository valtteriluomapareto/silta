import Dispatch
import Foundation
import GRDB
@testable import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(5)))
struct StorageStressTests {
  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func twentyConnectionsCommitFourThousandAdds() throws {
    try withScratchDirectory { home in
      let initial = StorageSchemaTests.store(home)
      try initial.initialize()
      let setup = try DatabaseQueue(path: initial.path)
      try setup.write {
        try $0.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      let failures = Mutex<[String]>([])
      let participants = Mutex<Set<Int>>([])
      let ready = DispatchGroup()
      let done = DispatchGroup()
      let start = DispatchSemaphore(value: 0)
      for index in 0..<20 {
        ready.enter()
        done.enter()
        Thread.detachNewThread {
          defer { done.leave() }
          ready.leave()
          start.wait()
          do {
            _ = participants.withLock { $0.insert(index) }
            try Self.addTwoHundred(home: home, index: index)
          } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
      }
      ready.wait()
      for _ in 0..<20 { start.signal() }
      done.wait()
      #expect(failures.withLock { $0.isEmpty }, "\(failures.withLock { $0 })")
      #expect(participants.withLock { $0.count } == 20)
      try initial.read { db in
        let taskCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM task")
        #expect(taskCount == 4000)
        let sequences = try Int64.fetchAll(db, sql: "SELECT seq FROM task ORDER BY seq")
        #expect(sequences == Array(1...4000))
        let changeCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log")
        #expect(changeCount == 4000)
        let changeSeq = try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='change_seq'")
        #expect(changeSeq == 4000)
        let nextSequence = try Int.fetchOne(
          db, sql: "SELECT next FROM seq_counter WHERE scope='acme'")
        #expect(nextSequence == 4001)
      }
    }
  }
  private static func addTwoHundred(home: URL, index: Int) throws {
    let store = StorageSchemaTests.store(home, seed: UInt64(index + 1))
    let ids = SeededIDGenerator(seed: UInt64(index))
    for _ in 0..<200 {
      let uid = try ids.next(at: StorageSchemaTests.instant)
      try store.write { transaction in
        let seq = try transaction.nextSequence(scope: "acme")
        try transaction.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,
            created_at,updated_at)
            VALUES(?,1,?,'Acme task','open','agent:unknown:acme','2023-11-14','2023-11-14')
            """, arguments: [uid, seq])
        try transaction.recordChange(
          kind: "task", rowID: transaction.database.lastInsertedRowID)
      }
    }
  }
}
