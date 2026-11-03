import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(3)))
struct DogfoodWorkflowTests {
  static let importer = ActorID.agent(tool: "codex", session: "acme-setup").description

  @Test func freshSessionFindsTheUntriagedImportAndKeepsOneTask() throws {
    try withScratchDirectory { scratch in
      let (clone, store) = try Self.prepare(scratch)
      let actor = ActorID.agent(tool: "codex", session: "acme-first").description
      func run(_ args: [String], actor: String) throws -> CLIResult {
        try Self.installed(args, scratch: scratch, clone: clone, actor: actor)
      }
      let plain = try run(["task", "ls"], actor: actor)
      #expect(plain.termination == .exit(0) && !plain.stdout.contains("SI-1"))
      let proposed = try run(
        ["task", "ls", "--proposed", "--promoted", "--archived"], actor: actor)
      #expect(proposed.stdout.contains("\"ref\":\"SI-1\""))
      #expect(proposed.stdout.contains("\"status\":\"proposed\""))
      #expect(proposed.stdout.contains("url:https://example.com/acme/7"))
      #expect(
        try run(
          ["task", "triage", "--accept", "SI-1", "--approved", "Work this Acme slice"], actor: actor
        ).termination == .exit(0))
      #expect(try run(["task", "start", "SI-1"], actor: actor).termination == .exit(0))
      #expect(
        try run(["task", "plan", "SI-1", "-m", "- [ ] Acme step"], actor: actor).termination
          == .exit(0))
      #expect(
        try run(["task", "plan", "SI-1", "--step", "1", "--done"], actor: actor).termination
          == .exit(0))
      let later = ActorID.agent(tool: "claude", session: "acme-later").description
      #expect(try run(["task", "start", "SI-1"], actor: later).termination == .exit(6))
      #expect(
        try run(["task", "done", "SI-1", "-m", "Acme done\nFriction: none"], actor: actor)
          .termination == .exit(0))
      let shown = try run(["task", "show", "SI-1"], actor: later)
      #expect(shown.termination == .exit(0) && shown.stdout.contains("\"done_sha\""))
      #expect(shown.stdout.contains("Acme done\\nFriction: none"))
      try store.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM task")
        #expect(count == 1)
      }
      try Self.checkLogs(scratch, later: later)
    }
  }

  @Test func archivedSliceTaskIsFoundOnlyWithArchivedByItsIssueLink() throws {
    try withScratchDirectory { scratch in
      let (clone, store) = try Self.prepare(scratch)
      try store.write {
        try $0.database.execute(
          sql: "UPDATE task SET status='dropped',archive_override='archived' WHERE seq=1")
      }
      let actor = ActorID.agent(tool: "codex", session: "acme-first").description
      let proposed = try Self.installed(
        ["task", "ls", "--proposed"], scratch: scratch, clone: clone, actor: actor)
      #expect(proposed.termination == .exit(0) && !proposed.stdout.contains("SI-1"))
      let all = try Self.installed(
        ["task", "ls", "--proposed", "--archived"], scratch: scratch, clone: clone, actor: actor)
      #expect(all.stdout.contains("\"ref\":\"SI-1\"") && all.stdout.contains("\"dropped\""))
      #expect(all.stdout.contains("url:https://example.com/acme/7"))
    }
  }

  @Test func setupCheckUsesAScratchTaskAndLeavesSlicesUntouched() throws {
    try withScratchDirectory { scratch in
      let (clone, store) = try Self.prepare(scratch)
      let actor = ActorID.agent(tool: "claude", session: "acme-check").description
      func run(_ args: [String]) throws -> CLIResult {
        try Self.installed(args, scratch: scratch, clone: clone, actor: actor)
      }
      #expect(try run(["task", "ls", "--proposed"]).stdout.contains("\"ref\":\"SI-1\""))
      let added = try run(["task", "add", "--start", "DF setup check", "--app", "silta"])
      #expect(added.termination == .exit(0) && added.stdout.contains("\"ref\":\"SI-2\""))
      #expect(
        try run(["task", "plan", "SI-2", "-m", "- [ ] Check the loop"]).termination == .exit(0))
      #expect(try run(["task", "plan", "SI-2", "--step", "1", "--done"]).termination == .exit(0))
      #expect(try run(["task", "drop", "SI-2", "-m", "Setup check only."]).termination == .exit(0))
      try store.read { db in
        let statuses = try String.fetchAll(db, sql: "SELECT status FROM task ORDER BY seq")
        #expect(statuses == ["proposed", "dropped"])
      }
    }
  }

  static func installed(_ args: [String], scratch: URL, clone: URL, actor: String) throws
    -> CLIResult
  {
    try SiltaBinary.runProcess(
      scratch.appending(path: "installed/silta"), ["--ws", "silta"] + args + ["--json"],
      in: scratch, cwd: clone, environment: ["SILTA_ACTOR": actor])
  }

  /// Installs the binary from a clean clone and imports one slice issue as the setup agent.
  static func prepare(_ scratch: URL) throws -> (URL, DatabaseStore) {
    let clone = try DogfoodInstallTests.clone(scratch)
    let store = try DogfoodImportTests.store(scratch)
    try store.write { tx in
      try tx.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) VALUES(1,?)", arguments: [clone.path])
    }
    let tools = scratch.appending(path: "tools")
    try DogfoodReportTests.tool(
      "swift",
      text: "#!/bin/bash\nmkdir -p .build/release\ncp " + shellWord(try SiltaBinary.url().path)
        + " .build/release/silta\n", in: tools)
    #expect(
      try DogfoodInstallTests.install(clone, scratch: scratch, tools: tools).termination
        == .exit(0))
    try DogfoodReportTests.tool(
      "gh",
      text: """
        #!/bin/bash
        echo '[[{"number":7,"title":"S7: Acme location","html_url":"https://example.com/acme/7"}]]'
        """, in: tools)
    let imported = try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [DogfoodReportTests.root.appending(path: "scripts/dogfood-import-issues.sh").path],
      in: scratch,
      environment: [
        "PATH": scratch.appending(path: "installed").path + ":" + tools.path + ":/usr/bin:/bin",
        "SILTA_ACTOR": importer,
      ])
    #expect(imported.termination == .exit(0))
    return (clone, store)
  }

  static func checkLogs(_ scratch: URL, later: String) throws {
    let directory = scratch.appending(path: "silta-home/log")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    let entries = try files.flatMap {
      try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init)
    }
    let laterEntries = try entries.compactMap { line -> [String: Any]? in
      let entry = try #require(
        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      return entry["actor"] as? String == later ? entry : nil
    }
    #expect(laterEntries.count == 2)
    #expect(
      laterEntries.allSatisfy {
        $0["workspace"] as? String == "silta" && $0["app"] == nil
      })
  }
}
