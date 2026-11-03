import Dispatch
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(10)))
struct TaskStressTests {
  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func twentyProcessesAddFourThousandTasksWithoutSequenceGaps() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let failures = Mutex<[String]>([])
      DispatchQueue.concurrentPerform(iterations: 20) { worker in
        do {
          let actor = ActorID.agent(tool: "codex", session: "worker\(worker)")
          for _ in 0..<200 {
            let result = try SiltaBinary.run(
              ["task", "add", "Acme task", "--json"], in: scratch,
              environment: ["SILTA_ACTOR": actor.description], timeout: 60)
            guard result.termination == .exit(0) else {
              failures.withLock { $0.append("\(result.termination): \(result.stdout)") }
              return
            }
          }
        } catch { failures.withLock { $0.append(String(describing: error)) } }
      }
      #expect(failures.withLock { $0.isEmpty }, "\(failures.withLock { $0 })")
      try store.read { (db: Database) throws in
        #expect(try Int64.fetchAll(db, sql: "SELECT seq FROM task ORDER BY seq") == Array(1...4000))
        #expect(try Int.fetchOne(db, sql: "SELECT count(DISTINCT uid) FROM task") == 4000)
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM task_event WHERE kind='created'") == 4000)
        #expect(
          try Int.fetchOne(db, sql: "SELECT count(*) FROM change_log WHERE kind='task'") == 4000)
        #expect(
          try Int.fetchOne(db, sql: "SELECT next FROM seq_counter WHERE scope='task:1'") == 4001)
      }
    }
  }

  @Test(.tags(.slow), .enabled(if: slowTestsEnabled()))
  func tenDistinctSessionsHaveExactlyOneSuccessfulClaim() throws {
    try withScratchDirectory { scratch in
      let store = try TaskCommandTests.setup(scratch)
      let actor = try ActorID.detect(
        environment: ["USER": "acme"],
        terminal: .init(stdin: true, stdout: true), session: "acme")
      try store.write {
        try $0.database.execute(
          sql: """
            INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
            VALUES('race',1,1,'Acme race','todo',?,?,?)
            """,
          arguments: [actor.description, "2023-11-14T22:13:20.000Z", "2023-11-14T22:13:20.000Z"])
      }
      let results = Mutex<[CLIResult]>([])
      let failures = Mutex<[String]>([])
      let ready = DispatchGroup()
      let done = DispatchGroup()
      let start = DispatchSemaphore(value: 0)
      for session in 0..<10 {
        ready.enter()
        done.enter()
        Thread.detachNewThread {
          defer { done.leave() }
          ready.leave()
          start.wait()
          do {
            let result = try SiltaBinary.run(
              ["task", "start", "AC-1", "--json"], in: scratch,
              environment: [
                "SILTA_ACTOR": ActorID.agent(tool: "codex", session: "race\(session)").description
              ])
            results.withLock { $0.append(result) }
          } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
      }
      ready.wait()
      for _ in 0..<10 { start.signal() }
      done.wait()
      #expect(failures.withLock { $0.isEmpty })
      let captured = results.withLock { $0 }
      #expect(captured.filter { $0.termination == .exit(0) }.count == 1)
      #expect(
        captured.filter { $0.termination == .exit(6) && $0.stdout.contains("\"code\":\"claimed\"") }
          .count == 9)
      #expect(captured.count == 10)
      #expect(
        try store.read {
          try Int.fetchOne($0, sql: "SELECT count(*) FROM task_event WHERE kind='claim'")
        } == 1)
    }
  }
}
