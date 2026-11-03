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

  @Test func reportMatchesWrittenMetricsAndPrivacyContract() throws {
    withKnownIssue("Report actor, unused commands and self-dropped proposals") {
      try withScratchDirectory { scratch in
        _ = try Self.setup(scratch)
        let tools = try Self.tools(scratch)
        let result = try Self.run(["--since", "2023-11-14"], scratch: scratch, tools: tools)
        #expect(result.termination == .exit(0))
        Golden.forTests().check(result.stdout, "dogfood-report.md")
        #expect(
          !result.stdout.contains("Acme foreign") && !result.stdout.contains("Acme private reply"))
        #expect(result.stderr.isEmpty)
      }
    }
  }

  @Test func newestReportDateAndFirstReportFallback() throws {
    withKnownIssue("Report actor, unused commands and self-dropped proposals") {
      try withScratchDirectory { scratch in
        _ = try DogfoodReportTests.setup(scratch)
        let tools = try DogfoodReportTests.tools(scratch)
        let folder = scratch.appending(path: "report-repo")
        let scripts = folder.appending(path: "scripts")
        let reports = folder.appending(path: "docs/dogfood/reports")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let script = scripts.appending(path: "dogfood-report.sh")
        try FileManager.default.copyItem(
          at: DogfoodReportTests.root.appending(path: "scripts/dogfood-report.sh"), to: script)
        let first = try DogfoodReportTests.run([], scratch: scratch, tools: tools, script: script)
        #expect(first.termination == .exit(0) && first.stdout.contains("Since: 1970-01-01"))
        #expect(
          first.stdout.contains(
            "Warning: --since predates the oldest log; calls before 2023-11-14 are missing."))
        for day in ["2023-11-13", "2023-11-14"] {
          try Data("Acme report".utf8).write(to: reports.appending(path: day + ".md"))
        }
        let next = try DogfoodReportTests.run([], scratch: scratch, tools: tools, script: script)
        #expect(next.termination == .exit(0))
        #expect(!next.stdout.contains("Warning:"))
        Golden.forTests().check(next.stdout, "dogfood-report.md")
      }
    }
  }

  @Test(arguments: ["2023-02-30", "2023-2-14", "nope", "2023-11-14;echo Acme"])
  func invalidDatesNeverPublish(date: String) throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let result = try DogfoodReportTests.run(["--since", date], scratch: scratch, tools: tools)
      #expect(result.termination != .exit(0) && result.stdout.isEmpty)
    }
  }

  @Test(arguments: ["list", "timeline", "schema", "sqlite", "missing", "asof"])
  func failedCollectionNeverPublishesPartialMarkdown(failure: String) throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let binary = shellWord(try SiltaBinary.url().path)
      switch failure {
      case "list", "timeline", "schema":
        let match = failure == "list" ? "task ls" : failure == "timeline" ? "task show" : "schema"
        try DogfoodReportTests.tool(
          "silta",
          text: "#!/bin/bash\n[[ \"$*\" == *" + shellWord(match) + "* ]] && exit 9\nexec " + binary
            + " \"$@\" --deterministic\n", in: tools)
      case "sqlite":
        try DogfoodReportTests.tool(
          "silta",
          text: """
            #!/bin/bash
            case "$*" in
              *'task ls'*) echo '{"ok":true,"data":{"tasks":[]}}';;
              *schema*) echo '{"ok":true,"data":{"commands":[]}}';;
            esac
            """, in: tools)
        try FileManager.default.removeItem(at: scratch.appending(path: "silta-home/silta.db"))
      case "missing":
        try FileManager.default.removeItem(at: tools.appending(path: "silta"))
      default:
        try DogfoodReportTests.tool(
          "date", text: "#!/bin/bash\necho Acme-invalid-time\n", in: tools)
      }
      let result = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination != .exit(0) && result.stdout.isEmpty)
      #expect(!result.stderr.contains("Acme foreign"))
    }
  }

  @Test func emptyWorkspaceHasRealZeroMeasurementsAndUnavailableInbox() throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodImportTests.store(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      try FileManager.default.removeItem(
        at: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let result = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("Logs available from: none."))
      #expect(result.stdout.contains("Untagged log lines: 0. Unreadable log lines: 0."))
      #expect(result.stdout.contains("0 sessions; median n/a; maximum n/a."))
      #expect(
        result.stdout.contains(
          "Proposals accepted: 0; dropped: 0; left untriaged past 14 days: 0."))
      #expect(result.stdout.contains("Oldest pending proposal: none."))
      #expect(result.stdout.contains("Triage wait: median n/a; maximum n/a."))
      #expect(result.stdout.contains("Done tasks without a Friction line: 0."))
      #expect(result.stdout.contains("## Calls\n\nNone.\n"))
      #expect(result.stdout.contains("## Warnings\n\nNone.\n"))
      #expect(result.stdout.contains("Open dogfood tasks:\n\nNone.\n"))
      #expect(result.stdout.contains("Inbox size and oldest item: n/a (S11)."))
    }
  }

  @Test func unreadableLogLinesAreCountedWithoutContent() throws {
    try withScratchDirectory { scratch in
      _ = try Self.setup(scratch)
      let tools = try Self.tools(scratch)
      let log = scratch.appending(path: "silta-home/log/2023-11-14.jsonl")
      let handle = try FileHandle(forWritingTo: log)
      try handle.seekToEnd()
      try handle.write(
        contentsOf: Data(
          """
          Acme foreign malformed content
          {"command":"Acme untagged without time","actor":"agent:codex:acme","exit_code":0}

          """.utf8))
      try handle.close()
      let result = try Self.run(["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("Untagged log lines: 2. Unreadable log lines: 2."))
      #expect(!result.stdout.contains("Acme foreign") && !result.stdout.contains("without time"))
    }
  }

  @Test func proposalExpiryPreservesMilliseconds() throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            UPDATE task_event
            SET created_at='2023-11-16T00:00:00.500Z'
            WHERE task_id=5 AND kind='created';
            UPDATE task_event
            SET created_at='2023-11-01T00:00:00.500Z'
            WHERE task_id=10 AND kind='created';
            UPDATE task_event
            SET created_at='2023-11-15T00:00:00.400Z'
            WHERE task_id=10 AND kind='status';
            """)
      }
      let tools = try DogfoodReportTests.tools(scratch)
      let report = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("left untriaged past 14 days: 0."))
      #expect(report.stdout.contains("Oldest pending proposal: 13 days."))
    }
  }

  @Test func reportRangeStartsAtSinceAndForeignContentIsNeverParsedAsMetrics() throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let entries: [[String: Any]] = [
        ["timestamp": "2023-11-14T00:00:00.000Z", "workspace": "silta"],
        ["timestamp": "2023-11-13T23:59:59.999Z", "workspace": "silta"],
        ["timestamp": "Acme private foreign date", "workspace": "acme"],
      ].map {
        $0.merging([
          "command": "silta task show", "actor": DogfoodReportTests.actor,
          "exit_code": 0, "milliseconds": 1, "warnings": [],
        ]) { first, _ in first }
      }
      let lines =
        try entries.map { try JSONSerialization.data(withJSONObject: $0) }
        .map { try #require(String(data: $0, encoding: .utf8)) }.joined(separator: "\n") + "\n"
      try Data(lines.utf8).write(
        to: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let report = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("| silta task show | 1 | 0% |"))
      #expect(!report.stdout.contains("Acme private"))
    }
  }

  @Test func approvalsUseTheISOWeekYear() throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodReportTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO approval(uid,workspace,actor,command,words,created_at)
            VALUES('acme-new-year','silta',?,'silta ws edit','Acme private',
              '2021-01-01T00:00:00.000Z')
            """, arguments: [DogfoodReportTests.actor])
      }
      let tools = try DogfoodReportTests.tools(scratch)
      let report = try DogfoodReportTests.run(
        ["--since", "2020-01-01"], scratch: scratch, tools: tools)
      #expect(report.termination == .exit(0))
      #expect(report.stdout.contains("| 2020-W53 | silta ws edit | 1 |"))
    }
  }

  @Test func reportTimeUsesAPortableDateAndKeepsItsOwnSecond() throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let entry: [String: Any] = [
        "timestamp": "2023-11-30T00:00:00.500Z", "workspace": "silta",
        "actor": DogfoodReportTests.actor, "command": "silta task show",
        "exit_code": 0, "milliseconds": 1, "warnings": [],
      ]
      let data = try JSONSerialization.data(withJSONObject: entry)
      try (data + Data("\n".utf8)).write(
        to: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let result = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("Until: 2023-11-30T00:00:00Z (UTC, report time)."))
      #expect(result.stdout.contains("| silta task show | 1 | 0% |"))
    }
  }
}

extension DogfoodReportTests {
  static func tool(_ name: String, text: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: name)
    try Data(text.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  }

  static func setup(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    try store.write { tx in
      try seedTasks(tx)
      try seedEvents(tx)
      try seedApprovals(tx)
    }
    return store
  }

  static func seedTasks(_ tx: StorageTransaction) throws {
    try tx.database.execute(
      sql: """
        INSERT INTO workspace(uid,slug,name,task_prefix)
        VALUES('silta-test', 'silta','Acme Silta','SI');
        INSERT INTO topic(uid,workspace_id,slug,name)
        VALUES('silta-dogfood',2,'dogfood','Dogfood');
        """)
    for seq in 1...12 {
      let status =
        seq <= 3 ? "done" : seq == 5 || seq == 6 ? "proposed" : seq == 8 ? "dropped" : "todo"
      let result =
        seq == 1
        ? "Acme result\nFriction: Re-reading the Acme plan was awkward."
        : seq == 2 ? "Friction: none" : seq == 3 ? "Friction: Old Acme friction." : nil
      try tx.database.execute(
        sql: """
          INSERT INTO task(uid,workspace_id,seq,title,status,result_md,created_by,
            created_at,updated_at)
          VALUES(?,2,?,?,?,?,?,?,?)
          """,
        arguments: [
          "silta-task-\(seq)", seq, seq == 4 ? "Acme command repair" : "Acme \(seq)",
          status, result, Self.actor, "2023-11-01T00:00:00.000Z", "2023-11-30T00:00:00.000Z",
        ])
    }
    try tx.database.execute(sql: "UPDATE task SET archive_override='archived' WHERE seq=1")
    try tx.database.execute(
      sql: """
        INSERT INTO task(uid,workspace_id,seq,title,status,result_md,created_by,
          created_at,updated_at)
        VALUES('acme-foreign-task',1,1,'Acme foreign task','done',
          'Friction: Acme foreign friction','agent:codex:acme','','');
        INSERT INTO task_event(task_id,actor,kind,body,created_at)
        VALUES(13,'agent:codex:acme','status','done','2023-11-14T00:00:00.000Z');
        """)
    try tx.database.execute(
      sql: """
        INSERT INTO link(uid,workspace_id,from_kind,from_id,rel,to_kind,to_id,
          created_by,created_at)
        VALUES('silta-topic-link',2,'task',4,'about','topic',1,'agent:codex:acme','');
        INSERT INTO task(uid,workspace_id,seq,title,status,result_md,created_by,
          created_at,updated_at)
        VALUES('silta-task-13',2,13,'Acme 13','done','Acme result without the line',?,
          '2023-11-01T00:00:00.000Z','2023-11-30T00:00:00.000Z');
        INSERT INTO task(uid,workspace_id,seq,title,status,result_md,created_by,
          created_at,updated_at)
        VALUES('silta-task-14',2,14,'Acme withdrawn idea','dropped','Acme withdrawn',?,
          '2023-11-20T00:00:00.000Z','2023-11-21T00:00:00.000Z');
        """, arguments: [Self.actor, Self.actor])
  }

  static func seedEvents(_ tx: StorageTransaction) throws {
    for (id, day) in [(1, "14"), (2, "15"), (3, "13"), (1, "15"), (14, "16")] {
      try event(id, kind: "status", body: "done", at: "2023-11-\(day)T10:00:00.000Z", in: tx)
    }
    for (seq, created) in [
      (5, "2023-11-16"), (6, "2023-11-17"), (7, "2023-11-14"),
      (8, "2023-11-14"), (9, "2023-10-30"), (10, "2023-11-01"), (11, "2023-11-01"),
      (12, "2023-11-01"), (15, "2023-11-20"),
    ] {
      try event(seq, kind: "created", body: "proposed", at: created + "T00:00:00.000Z", in: tx)
    }
    for (seq, date) in [
      (7, "2023-11-14T00:30:00.000Z"), (8, "2023-11-14T01:00:00.000Z"),
      (9, "2023-11-20T00:00:00.000Z"), (10, "2023-11-15T00:00:00.000Z"),
      (11, "2023-11-14T23:59:59.000Z"), (12, "2023-11-16T00:00:00.000Z"),
      (15, "2023-11-21T00:00:00.000Z"),
    ] {
      try event(
        seq, kind: "status", body: seq == 8 || seq == 15 ? "dropped" : "todo", at: date, in: tx)
    }
  }

  static func seedApprovals(_ tx: StorageTransaction) throws {
    for (index, command) in [
      "silta task start 'SI-1' --steal", "silta task start 'SI-2' --steal",
      "silta ws edit 'silta'", "silta task triage --accept 'SI-7'", "silta ws edit 'silta'",
    ].enumerated() {
      try tx.database.execute(
        sql: """
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
          VALUES(?,'silta',?,?,?,?)
          """,
        arguments: [
          "silta-approval-\(index)", Self.actor, command,
          "Acme private reply",
          index < 3 ? "2023-11-14T12:00:00.000Z" : "2023-11-21T12:00:00.000Z",
        ])
    }
    try tx.database.execute(
      sql: """
        INSERT INTO approval(uid,workspace,actor,command,words,created_at)
        VALUES('acme-foreign-approval','acme','agent:codex:acme',
          'Acme foreign command','Acme foreign reply','2023-11-14');
        """)
    for (uid, actor, command) in [
      ("silta-report-approval", "agent:silta:dogfood-report", "silta task start 'SI-3' --steal"),
      ("silta-other-approval", Self.actor, "silta frobnicate 'SI-3'"),
    ] {
      try tx.database.execute(
        sql: """
          INSERT INTO approval(uid,workspace,actor,command,words,created_at)
          VALUES(?,'silta',?,?,'Acme private reply','2023-11-14T12:00:00.000Z')
          """, arguments: [uid, actor, command])
    }
    try tx.database.execute(
      sql: """
        INSERT INTO approval(uid,workspace,actor,command,words,created_at)
        VALUES('silta-drop-approval','silta',?,?,
          'Acme private reply','2023-11-14T01:00:00.000Z')
        """, arguments: [Self.actor, "silta task triage --drop 'SI-8'"])
  }

  static func event(_ id: Int, kind: String, body: String, at: String, in tx: StorageTransaction)
    throws
  {
    try tx.database.execute(
      sql: """
        INSERT INTO task_event(task_id,actor,kind,body,created_at)
        VALUES(?,?,?,?,?)
        """, arguments: [id, Self.actor, kind, body, at])
  }

  static func tools(_ scratch: URL) throws -> URL {
    let tools = scratch.appending(path: "tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try tool(
      "silta",
      text: "#!/bin/bash\nexec " + shellWord(try SiltaBinary.url().path)
        + " \"$@\" --deterministic\n", in: tools)
    try tool(
      "date",
      text: """
        #!/bin/bash
        [[ "$*" == '-u +%Y-%m-%dT%H:%M:%SZ' ]] || exit 1
        echo 2023-11-30T00:00:00Z
        """,
      in: tools)
    let log = scratch.appending(path: "silta-home/log")
    try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
    let fixture = root.appending(path: "Tests/siltaTests/Golden/dogfood-log-input.jsonl")
    try FileManager.default.copyItem(at: fixture, to: log.appending(path: "2023-11-14.jsonl"))
    return tools
  }

  static func run(_ args: [String], scratch: URL, tools: URL, script: URL? = nil) throws
    -> CLIResult
  {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [(script ?? root.appending(path: "scripts/dogfood-report.sh")).path] + args,
      in: scratch,
      environment: [
        "PATH": tools.path + ":/usr/bin:/bin", "SILTA_ACTOR": actor,
        "SILTA_NOW": "2023-11-30T00:00:00.000Z",
      ])
  }
}

extension DogfoodReportTests {
  static func line(_ overrides: [String: Any]) throws -> String {
    let base: [String: Any] = [
      "timestamp": "2023-11-14T10:00:00.000Z", "workspace": "silta",
      "actor": "agent:codex:acme-c", "command": "silta task ls", "exit_code": 0,
      "milliseconds": 1, "warnings": [String](),
    ]
    let object = base.merging(overrides) { _, new in new }
    return try #require(
      String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
  }

  @Test func truncatedLogFileNeverSwallowsTheNextFile() throws {
    withKnownIssue("Log files are concatenated before splitting lines") {
      try withScratchDirectory { scratch in
        _ = try Self.setup(scratch)
        let tools = try Self.tools(scratch)
        let log = scratch.appending(path: "silta-home/log")
        try Data(#"{"timestamp":"2023-11-13T23:00:00.000Z","comm"#.utf8).write(
          to: log.appending(path: "2023-11-13.jsonl"))
        let next = try String(
          contentsOf: log.appending(path: "2023-11-14.jsonl"), encoding: .utf8)
        let first = try Self.line(["timestamp": "2023-11-14T09:00:00.000Z"])
        try Data((first + "\n" + next).utf8).write(to: log.appending(path: "2023-11-14.jsonl"))
        let result = try Self.run(["--since", "2023-11-14"], scratch: scratch, tools: tools)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("Unreadable log lines: 1."))
        #expect(result.stdout.contains("| silta task ls | 2 | 0% |"))
      }
    }
  }

  @Test(arguments: ["actor", "warnings", "command"])
  func wronglyShapedLogLinesAreUnreadable(field: String) throws {
    withKnownIssue("A wrongly shaped log line aborts the report") {
      try withScratchDirectory { scratch in
        _ = try Self.setup(scratch)
        let tools = try Self.tools(scratch)
        let log = scratch.appending(path: "silta-home/log/2023-11-14.jsonl")
        let wrong: Any = field == "warnings" ? "Acme" : field == "actor" ? 5 : ["silta"]
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try Self.line([field: wrong]) + "\n").utf8))
        try handle.close()
        let result = try Self.run(["--since", "2023-11-14"], scratch: scratch, tools: tools)
        #expect(result.termination == .exit(0))
        #expect(result.stdout.contains("Unreadable log lines: 1."))
        #expect(result.stdout.contains("| silta task ls | 1 | 0% |"))
      }
    }
  }

  @Test func sinceAfterTheReportDayIsRefused() throws {
    withKnownIssue("A --since after Until prints an empty report") {
      try withScratchDirectory { scratch in
        _ = try Self.setup(scratch)
        let tools = try Self.tools(scratch)
        let result = try Self.run(["--since", "2023-12-01"], scratch: scratch, tools: tools)
        #expect(result.termination == .exit(1) && result.stdout.isEmpty)
        #expect(result.stderr.contains("2023-11-30"))
      }
    }
  }
}
