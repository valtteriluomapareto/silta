import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodReportTests {
  static let actor = ActorID.agent(tool: "codex", session: "acme").description

  static var root: URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  static func tool(_ name: String, text: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: name)
    try Data(text.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  }

  static func setup(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    try store.write { tx in
      try tx.database.execute(sql: """
        INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('silta-test', 'silta','Acme Silta','SI');
        INSERT INTO topic(uid,workspace_id,slug,name) VALUES('silta-dogfood',2,'dogfood','Dogfood');
        """)
      for seq in 1...12 {
        let status = seq <= 3 ? "done" : seq == 5 || seq == 6 ? "proposed" : seq == 8 ? "dropped" : "todo"
        let result = seq == 1 ? "Acme result\nFriction: Re-reading the Acme plan was awkward."
          : seq == 2 ? "Friction: none" : seq == 3 ? "Friction: Old Acme friction." : nil
        try tx.database.execute(sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,result_md,created_by,created_at,updated_at)
          VALUES(?,2,?,?,?,?,?,?,?)
          """, arguments: ["silta-task-\(seq)", seq, seq == 4 ? "Acme command repair" : "Acme \(seq)",
            status, result, Self.actor, "2023-11-01T00:00:00.000Z", "2023-11-30T00:00:00.000Z"])
      }
      try tx.database.execute(sql: """
        INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,created_by,created_at)
        VALUES('silta-topic-link',2,'task',4,'about','topic',1,'agent:codex:acme','');
        """)
      for (seq, day) in [(1, "14"), (2, "15"), (3, "13")] {
        try event(seq, kind: "status", body: "done", at: "2023-11-\(day)T10:00:00.000Z", in: tx)
      }
      for (seq, created) in [(5, "2023-11-16"), (6, "2023-11-17"), (7, "2023-11-14"),
        (8, "2023-11-14"), (9, "2023-10-30"), (10, "2023-11-01"), (11, "2023-11-01"), (12, "2023-11-01")] {
        try event(seq, kind: "created", body: "proposed", at: created + "T00:00:00.000Z", in: tx)
      }
      for (seq, date) in [(7, "2023-11-14T00:30:00.000Z"), (8, "2023-11-14T01:00:00.000Z"),
        (9, "2023-11-20T00:00:00.000Z"), (10, "2023-11-15T00:00:00.000Z"),
        (11, "2023-11-14T23:59:59.000Z"), (12, "2023-11-16T00:00:00.000Z")] {
        try event(seq, kind: "status", body: seq == 8 ? "dropped" : "todo", at: date, in: tx)
      }
      for (index, command) in ["silta task start 'SI-1' --steal", "silta task start 'SI-2' --steal",
        "silta ws edit 'silta'", "silta task triage --accept 'SI-7'", "silta ws edit 'silta'"].enumerated() {
        try tx.database.execute(sql: """
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
          VALUES(?,'silta',?,?,?,?)
          """, arguments: ["silta-approval-\(index)", Self.actor, command,
            "Acme private reply", index < 3 ? "2023-11-14T12:00:00.000Z" : "2023-11-21T12:00:00.000Z"])
      }
      try tx.database.execute(sql: """
        INSERT INTO approval(uid,workspace,actor,command,words,created_at)
        VALUES('acme-foreign-approval','acme','agent:codex:acme','Acme foreign command','Acme foreign reply','2023-11-14');
        """)
    }
    return store
  }

  static func event(_ id: Int, kind: String, body: String, at: String, in tx: StorageTransaction) throws {
    try tx.database.execute(sql: """
      INSERT INTO task_event(task_id,actor,kind,body,created_at)
      VALUES(?,?,?,?,?)
      """, arguments: [id, Self.actor, kind, body, at])
  }

  @Test func reportMatchesWrittenMetricsAndPrivacyContract() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let tools = scratch.appending(path: "tools")
      try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: tools.appending(path: "silta"), withDestinationURL: SiltaBinary.url())
      try Self.tool("date", text: "#!/bin/bash\nif [[ \"$*\" == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then echo 2023-11-30T00:00:00Z; else exec /bin/date \"$@\"; fi\n", in: tools)
      let log = scratch.appending(path: "silta-home/log")
      try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
      let fixture = Self.root.appending(path: "Tests/siltaTests/Golden/dogfood-log-input.jsonl")
      try FileManager.default.copyItem(at: fixture, to: log.appending(path: "2023-11-14.jsonl"))
      let result = try SiltaBinary.runProcess(URL(filePath: "/bin/bash"),
        [Self.root.appending(path: "scripts/dogfood-report.sh").path, "--since", "2023-11-14"],
        in: scratch, environment: ["PATH": tools.path + ":/usr/bin:/bin", "SILTA_ACTOR": Self.actor])
      #expect(result.termination == .exit(0))
      Golden.forTests().check(result.stdout, "dogfood-report.md")
      #expect(!result.stdout.contains("Acme foreign") && !result.stdout.contains("Acme private reply"))
      #expect(result.stderr.isEmpty)
    }
  }
}
