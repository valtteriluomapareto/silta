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
        try $0.execute(sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      let failures = Mutex<[String]>([])
      let participants = Mutex<Set<Int>>([])
      DispatchQueue.concurrentPerform(iterations: 20) { index in
        do {
          let store = StorageSchemaTests.store(home, seed: UInt64(index + 1))
          let ids = SeededIDGenerator(seed: UInt64(index))
          participants.withLock { $0.insert(index) }
          for _ in 0..<200 {
            let uid = try ids.next(at: StorageSchemaTests.instant)
            try store.write { transaction in
              let seq = try transaction.nextSequence(scope: "acme")
              try transaction.database.execute(
                sql: """
                  INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
                  VALUES(?,1,?,'Acme task','open','agent:unknown:acme','2023-11-14','2023-11-14')
                  """, arguments: [uid, seq])
              try transaction.recordChange(kind: "task", rowID: transaction.database.lastInsertedRowID)
            }
          }
        } catch { failures.withLock { $0.append(String(describing: error)) } }
      }
      #expect(failures.withLock { $0.isEmpty }, "\(failures.withLock { $0 })")
      #expect(participants.withLock { $0.count } == 20)
      try initial.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM task") == 4000)
        #expect(try Int64.fetchAll(db, sql: "SELECT seq FROM task ORDER BY seq") == Array(1...4000))
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log") == 4000)
        #expect(try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key='change_seq'") == 4000)
        #expect(try Int.fetchOne(db, sql: "SELECT next FROM seq_counter WHERE scope='acme'") == 4001)
      }
    }
  }
}
