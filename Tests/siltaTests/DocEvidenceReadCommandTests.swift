import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocEvidenceReadCommandTests {
  @Test(arguments: [false, true], [false, true])
  func recordedEvidenceKeepsProposerAndOutputContract(json: Bool, quiet: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let before = try truth(store)
      let result = try run([], scratch, json: json, quiet: quiet)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      Golden.forTests().check(result.stdout, "doc-evidence." + (json ? "json" : "txt"))
      #expect(try truth(store) == before)
    }
  }

  @Test(arguments: [false, true])
  func evidenceOnlyChangesAppearAgainstRecordedBase(json: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      let before = try truth(store)
      let result = try run(["--diff"], scratch, json: json)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      Golden.forTests().check(result.stdout, "doc-evidence-diff." + (json ? "json" : "txt"))
      #expect(!result.stdout.contains("-Same body") && !result.stdout.contains("+Same body"))
      #expect(try truth(store) == before)
    }
  }

  @Test(arguments: [false, true])
  func unknownEvidenceAndRecordedEmptyWhyAreDistinct(empty: Bool) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE doc_rev SET message=?,source_task_id=NULL,triaged_by=NULL,triaged_at=NULL WHERE rev=2",
          arguments: [empty ? "" : nil])
      }
      let result = try run([], scratch)
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "doc-evidence-" + (empty ? "empty" : "unknown") + ".txt")
      #expect(!result.stdout.contains("human:reviewer"))
    }
  }

  @Test(arguments: ["accepted", "proposed", "rejected", "superseded"])
  func allReadableStatesUseRecordedSourceWithoutLiveClaim(state: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc_rev SET state=? WHERE rev=2", arguments: [state])
        try $0.database.execute(sql: "UPDATE task SET status='done',claimed_by=NULL,claimed_at=NULL")
        try $0.database.execute(sql: "UPDATE doc SET archived=1")
      }
      let before = try truth(store)
      let result = try run([], scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.hasPrefix("doc:rules@2 [\(state), archived]\n"))
      #expect(result.stdout.contains("source_task: AC-1\n"))
      #expect(result.stdout.contains("actor: agent:codex:writer\n"))
      #expect(result.stdout.contains("triaged_by: human:reviewer\n"))
      #expect(try truth(store) == before)
    }
  }

  @Test(arguments: ["missing-source", "foreign-source", "half-actor", "half-time"])
  func brokenRecordedEvidenceIsCorruptWithoutFallback(failure: String) throws {
    try withScratchDirectory { scratch in
      let store = try fixture(scratch)
      var config = Configuration()
      config.foreignKeysEnabled = false
      let queue = try DatabaseQueue(path: store.path, configuration: config)
      try queue.write { db in
        switch failure {
        case "missing-source":
          try db.execute(sql: "UPDATE doc_rev SET source_task_id=999 WHERE rev=2")
        case "foreign-source":
          try db.execute(sql: "INSERT INTO workspace(id,uid,slug,name,task_prefix) VALUES(2,'beta','beta','Beta','BE')")
          try db.execute(sql: "UPDATE task SET workspace_id=2")
        case "half-actor": try db.execute(sql: "UPDATE doc_rev SET triaged_at=NULL WHERE rev=2")
        default: try db.execute(sql: "UPDATE doc_rev SET triaged_by=NULL WHERE rev=2")
        }
      }
      let before = try truth(store)
      for flags in [[], ["--diff"]] {
        for json in [false, true] {
          let result = try run(flags, scratch, json: json)
          #expect(result.termination == .exit(9))
          Golden.forTests().check(
            json ? result.stdout : result.stderr,
            "doc-evidence-corrupt." + (json ? "json" : "txt"))
          #expect(json ? result.stderr.isEmpty : result.stdout.isEmpty)
        }
      }
      #expect(try truth(store) == before)
    }
  }

  func run(_ flags: [String], _ scratch: URL, json: Bool = false, quiet: Bool = false) throws
    -> CLIResult
  {
    try SiltaBinary.run(
      ["--ws", "acme", "doc", "show", "doc:rules@2"] + flags
        + (json ? ["--json"] : []) + (quiet ? ["--quiet"] : []), in: scratch)
  }

  func fixture(_ scratch: URL) throws -> DatabaseStore {
    let store = try AcmeDocAttachments.make(in: scratch)
    try AcmeDocAttachments.attach("rules", to: "app", in: store)
    try store.write {
      try $0.database.execute(sql: """
        INSERT INTO task(uid,workspace_id,seq,title,status,created_by,created_at,updated_at)
        VALUES('source',1,1,'Recorded source','done','human:acme','2023-11-14','2023-11-14');
        UPDATE doc_rev SET body_md='Same body',title='Rules',kind='contract',
          about_refs='["app:api"]',actor='agent:codex:base',created_at='2023-11-14' WHERE rev=1;
        INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,created_at,
          title,kind,about_refs,message,source_task_id,triaged_by,triaged_at)
        SELECT 'recorded',id,2,1,'Same body','rejected','agent:codex:writer','2023-11-15',
          'Rules','contract','["app:api"]','Line one'||char(10)||'Line two',
          (SELECT id FROM task WHERE uid='source'),'human:reviewer','2023-11-16' FROM doc;
        """)
    }
    return store
  }

  func truth(_ store: DatabaseStore) throws -> [[String]] {
    try store.read { db in
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      return try tables.map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid").map(\.description) }
    }
  }
}
