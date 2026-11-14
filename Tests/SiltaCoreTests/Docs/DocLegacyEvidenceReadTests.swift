import Foundation
import GRDB
import SiltaTestSupport
import Testing

@testable import SiltaCore

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocLegacyEvidenceReadTests {
  @Test(arguments: ["v1", "v2", "v3", "v4"])
  func historicalSchemasReadWhyAndDiffWithoutMigration(version: String) throws {
    try withScratchDirectory { scratch in
      let (store, queue) = try fixture(scratch, version: version)
      let before = try DocVerificationPreparationTests.truth(store)
      let columns = try queue.read { try $0.columns(in: "doc_rev").map(\.name) }
      #expect(!columns.contains("source_task_id") && !columns.contains("title"))
      for flags in [[], ["--diff"]] {
        for json in [false, true] {
          let result = try SiltaBinary.run(
            ["--ws", "acme", "doc", "show", "doc:rules@2"] + flags
              + (json ? ["--json"] : []), in: scratch)
          #expect(result.termination == .exit(0))
          #expect(result.stdout.contains("Legacy why"))
          if flags.isEmpty {
            #expect(result.stdout.contains("title: (unknown)"))
            #expect(result.stdout.contains("source_task: (not recorded)"))
            #expect(result.stdout.contains("triaged_by: (not recorded)"))
          } else {
            #expect(result.stdout.contains("diff against doc:rules@1"))
          }
          #expect(!result.stdout.contains("Projection title"))
        }
      }
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      let migrations = try queue.read {
        try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
      }
      #expect(migrations.last == version && !migrations.contains("v5"))
    }
  }
  @Test(arguments: ["v1", "v2", "v3", "v4"], [false, true])
  func historicalListsKeepPendingRecoveryAndUnknownMetadata(version: String, archived: Bool) throws
  {
    try withScratchDirectory { scratch in
      let (store, queue) = try listFixture(scratch, version: version, archived: archived)
      let before = try DocVerificationPreparationTests.truth(store)
      let migrations = try queue.read {
        try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
      }
      #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM doc_rev") } == 4)
      for (flags, total) in [
        ([String](), archived ? 0 : 4),
        (["--archived", "--offset", "0", "--limit", "20"], 4),
        (["--archived", "--about", "app:api"], 4),
        (["--archived", "--about", "app:other"], 0),
      ] {
        for json in [false, true] {
          let result = try SiltaBinary.run(
            ["--ws", "acme", "doc", "ls"] + flags + (json ? ["--json"] : []), in: scratch)
          withKnownIssue("Historical list queries must not require later revision metadata") {
            #expect(result.termination == .exit(0) && result.stderr.isEmpty)
            #expect(result.stdout.contains(json ? "\"total\":\(total)" : "total \(total))"))
            if total > 0 {
              #expect(result.stdout.contains("doc:rules@4") && result.stdout.contains("(unknown)"))
            }
            #expect(!result.stdout.contains("Projection title"))
          }
        }
      }
      withKnownIssue("Historical global continuation must reveal every omitted member") {
        try replayListPages(scratch)
      }
      let missing = try SiltaBinary.run(
        ["--ws", "acme", "doc", "ls", "--about", "app:missing", "--json"], in: scratch)
      #expect(missing.termination == .exit(2))
      #expect(try DocVerificationPreparationTests.truth(store) == before)
      #expect(
        try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
          == migrations)
      #expect(migrations.last == version && !migrations.contains("v5"))
    }
  }

  private func listFixture(_ scratch: URL, version: String, archived: Bool) throws
    -> (DatabaseStore, DatabaseQueue)
  {
    let (store, queue) = try fixture(scratch, version: version)
    try queue.write {
      try $0.execute(
        sql: """
          INSERT INTO repo(id,uid,workspace_id,slug) VALUES(1,'platform',1,'platform');
          INSERT INTO app(id,uid,workspace_id,slug,name,repo_id,ref)
          VALUES(1,'api',1,'api','API',1,'main'),(2,'other',1,'other','Other',1,'other');
          INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
          VALUES('about',1,'doc',1,'about','app',1,'human:acme','2023-11-14');
          INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,created_at)
          VALUES('third',1,3,1,'Third','proposed','agent:codex:writer','2023-11-15'),
            ('fourth',1,4,1,'Fourth','proposed','agent:codex:writer','2023-11-15');
          UPDATE doc SET archived=?;
          """, arguments: [archived])
    }
    return (store, queue)
  }

  private func replayListPages(_ scratch: URL) throws {
    var command: String? = "silta --ws 'acme' doc ls --archived --offset 0 --limit 1"
    var refs: Set<String> = []
    for _ in 0..<4 {
      guard let current = command else { break }
      let result = try SiltaBinary.runProcess(
        URL(filePath: "/bin/sh"),
        [
          "-c", "exec \"$1\"" + String(current.dropFirst(5)),
          "_", try SiltaBinary.url().path,
        ], in: scratch)
      #expect(result.termination == .exit(0) && result.stderr.isEmpty)
      let lines = result.stdout.components(separatedBy: "\n")
      for line in lines where line.hasPrefix("doc:rules@") {
        if let ref = line.split(separator: " ").first { refs.insert(String(ref)) }
      }
      command = lines.first { $0.hasPrefix("next: ") }.map { String($0.dropFirst(6)) }
    }
    #expect(refs == Set((1...4).map { "doc:rules@\($0)" }))
    #expect(command == nil)
  }

  private func fixture(_ scratch: URL, version: String) throws -> (DatabaseStore, DatabaseQueue) {
    let home = scratch.appending(path: "silta-home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let store = DatabaseStore(
      home: home, clock: FakeClock(now: AcmeDocAttachments.instant), jitter: { 0 })
    let queue = try DatabaseQueue(path: store.path)
    try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=WAL") }
    try StorageSchema.migrator.migrate(queue, upTo: version)
    try queue.write {
      try $0.execute(
        sql: """
          INSERT INTO workspace(id,uid,slug,name,task_prefix)
          VALUES(1,'acme','acme','Acme','AC');
          INSERT INTO doc(id,uid,workspace_id,slug,title,kind,current_rev,created_at,updated_at)
          VALUES(1,'rules',1,'rules','Projection title','reference',1,'2023-11-14','2023-11-14');
          INSERT INTO doc_rev(uid,doc_id,rev,body_md,state,actor,created_at)
          VALUES('base',1,1,'Base body','accepted','human:acme','2023-11-14');
          INSERT INTO doc_rev(uid,doc_id,rev,base_rev,body_md,state,actor,created_at,message)
          VALUES('next',1,2,1,'Next body','proposed',
            'agent:codex:writer','2023-11-15','Legacy why');
          """)
    }
    return (store, queue)
  }

}
