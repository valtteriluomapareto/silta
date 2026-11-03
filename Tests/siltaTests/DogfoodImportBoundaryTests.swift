import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodImportBoundaryTests {
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

  @Test(arguments: ["empty", "github", "malformed", "list"])
  func emptyAndFailedImportsDoNotCreateTasks(mode: String) throws {
    try withScratchDirectory { scratch in
      let store = try DogfoodToolingTests.importStore(scratch)
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
      let store = try DogfoodToolingTests.importStore(scratch)
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
