import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodImportTests {
  static func store(_ scratch: URL) throws -> DatabaseStore {
    let store = try TaskCommandTests.setup(scratch)
    try store.write { tx in
      try tx.database.execute(
        sql: """
          INSERT INTO workspace(uid,slug,name,task_prefix)
          VALUES('silta','silta','Acme Silta','SI');
          INSERT INTO repo(uid,workspace_id,slug) VALUES('silta-repo',2,'silta');
          INSERT INTO app(uid,workspace_id,slug,name,repo_id,ref)
          VALUES('silta-app',2,'silta','Acme Silta',1,'main');
          """)
    }
    return store
  }

  static func run(_ scratch: URL, tools: URL) throws -> CLIResult {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [DogfoodReportTests.root.appending(path: "scripts/dogfood-import-issues.sh").path],
      in: scratch,
      environment: [
        "PATH": tools.path + ":/usr/bin:/bin",
        "SILTA_ACTOR": DogfoodReportTests.actor,
      ])
  }

  static func githubPages(_ scratch: URL, tools: URL) throws {
    let other = (1...31).map {
      ["number": $0, "title": "Acme documentation", "html_url": "https://example.com/acme/\($0)"]
        as [String: Any]
    }
    let match: [String: Any] = [
      "number": 40, "title": "S7: Acme location", "html_url": "https://example.com/acme/40",
    ]
    let data = try JSONSerialization.data(withJSONObject: [
      other,
      [
        match, match,
        ["number": 41, "title": "DF: Acme report", "html_url": "https://example.com/acme/41"],
        [
          "number": 42, "title": "S99: Acme pull request",
          "html_url": "https://example.com/acme/42", "pull_request": [:],
        ],
      ],
    ])
    let pages = scratch.appending(path: "pages.json")
    try data.write(to: pages)
    try DogfoodReportTests.tool(
      "gh",
      text: "#!/bin/bash\n[[ \"$1 $2 $3\" == 'api --paginate --slurp' ]] || exit 98\ncat "
        + shellWord(pages.path) + "\n", in: tools)
  }

  @Test func paginatedIssueImportIsIdempotentAndExplicitlyScoped() throws {
    withKnownIssue("DF issues are imported as slices") {
      try withScratchDirectory { scratch in
        let store = try Self.store(scratch)
        let tools = scratch.appending(path: "tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
          at: tools.appending(path: "silta"), withDestinationURL: SiltaBinary.url())
        try Self.githubPages(scratch, tools: tools)
        for index in 0..<2 {
          let result = try Self.run(scratch, tools: tools)
          #expect(result.termination == .exit(0) && result.stdout.contains("Next:"))
          if index == 0 {
            try store.write { tx in
              try tx.database.execute(
                sql: "UPDATE task SET archive_override='archived',created_by=?",
                arguments: [ActorID.agent(tool: "claude", session: "acme-other").description])
            }
          }
        }
        try store.read { db in
          let rows = try Row.fetchAll(db, sql: "SELECT workspace_id,status,app_id FROM task")
          #expect(
            rows.count == 1
              && rows.allSatisfy { $0["workspace_id"] as Int64 == 2 && $0["app_id"] as Int64? == 1 }
          )
          #expect(rows.allSatisfy { $0["status"] as String == "proposed" })
          let links = try String.fetchAll(db, sql: "SELECT to_ext FROM link ORDER BY to_ext")
          #expect(links == ["https://example.com/acme/40"])
          #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM approval") == 0)
        }
      }
    }
  }

  static func issues(_ titles: [Int: String], tools: URL) throws {
    let issues = titles.sorted { $0.key < $1.key }.map {
      ["number": $0.key, "title": $0.value, "html_url": "https://example.com/acme/\($0.key)"]
        as [String: Any]
    }
    let json = try #require(
      String(data: try JSONSerialization.data(withJSONObject: [issues]), encoding: .utf8))
    try DogfoodReportTests.tool(
      "gh", text: "#!/bin/bash\necho " + shellWord(json) + "\n", in: tools)
  }

  static func linkedTools(_ scratch: URL) throws -> URL {
    let tools = scratch.appending(path: "tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: tools.appending(path: "silta"), withDestinationURL: SiltaBinary.url())
    return tools
  }

  @Test func failedSiltaReadPrintsItsErrorAndNext() throws {
    withKnownIssue("JSON errors are captured and the script exits silently") {
      try withScratchDirectory { scratch in
        _ = try TaskCommandTests.setup(scratch)
        let tools = try Self.linkedTools(scratch)
        try Self.issues([7: "S7: Acme location"], tools: tools)
        let result = try Self.run(scratch, tools: tools)
        #expect(result.termination == .exit(1))
        #expect(result.stderr.contains("not_found") && result.stderr.contains("Next: silta ws"))
      }
    }
  }

  @Test func rerunNamesEveryUntriagedImport() throws {
    withKnownIssue("Next names only the proposals created in this run") {
      try withScratchDirectory { scratch in
        _ = try Self.store(scratch)
        let tools = try Self.linkedTools(scratch)
        try Self.issues([7: "S7: Acme location"], tools: tools)
        #expect(try Self.run(scratch, tools: tools).termination == .exit(0))
        try Self.issues([7: "S7: Acme location", 8: "S8: Acme brief"], tools: tools)
        let rerun = try Self.run(scratch, tools: tools)
        #expect(rerun.termination == .exit(0))
        let next = try #require(rerun.stdout.split(separator: "\n").last)
        #expect(next.contains("task triage --accept SI-1 SI-2 --approved"))
      }
    }
  }

  @Test(arguments: ["empty", "github", "malformed", "list"])
  func emptyAndFailedImportsDoNotCreateTasks(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try Self.store(scratch)
      let tools = scratch.appending(path: "tools")
      let gh =
        mode == "github" ? "exit 9" : mode == "malformed" ? "echo Acme-invalid" : "echo '[[]]'"
      try DogfoodReportTests.tool("gh", text: "#!/bin/bash\n" + gh + "\n", in: tools)
      let cli =
        mode == "list" ? "exit 9" : "exec " + shellWord(try SiltaBinary.url().path) + " \"$@\""
      try DogfoodReportTests.tool("silta", text: "#!/bin/bash\n" + cli + "\n", in: tools)
      let result = try Self.run(scratch, tools: tools)
      #expect(mode == "empty" ? result.termination == .exit(0) : result.termination != .exit(0))
      try store.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM task")
        #expect(count == 0)
      }
    }
  }

  @Test func printedLinkRepairMakesInterruptedImportSafeToRerun() throws {
    try withScratchDirectory { scratch in
      let store = try Self.store(scratch)
      let tools = scratch.appending(path: "tools")
      try DogfoodReportTests.tool(
        "gh",
        text: """
          #!/bin/bash
          echo '[[{"number":7,"title":"S7: Acme","html_url":"https://example.com/acme/7"}]]'
          """, in: tools)
      let binary = shellWord(try SiltaBinary.url().path)
      try DogfoodReportTests.tool(
        "silta",
        text: "#!/bin/bash\n[[ \"$*\" == *'task link'* ]] && exit 9\nexec " + binary + " \"$@\"\n",
        in: tools)
      let failed = try Self.run(scratch, tools: tools)
      #expect(failed.termination != .exit(0))
      let line = try #require(failed.stderr.split(separator: "\n").last)
      #expect(line.hasPrefix("Next: silta --ws silta task link SI-1"))
      try DogfoodReportTests.tool(
        "silta", text: "#!/bin/bash\nexec " + binary + " \"$@\"\n", in: tools)
      let repaired = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        ["-c", String(line.dropFirst(6))], in: scratch,
        environment: [
          "PATH": tools.path + ":/usr/bin:/bin", "SILTA_ACTOR": DogfoodReportTests.actor,
        ])
      #expect(repaired.termination == .exit(0))
      #expect(try Self.run(scratch, tools: tools).termination == .exit(0))
      try store.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM task")
        let links = try Int.fetchOne(db, sql: "SELECT count(*) FROM link")
        #expect(count == 1 && links == 1)
      }
    }
  }
}
