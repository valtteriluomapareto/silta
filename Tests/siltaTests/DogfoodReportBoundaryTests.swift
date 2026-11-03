import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(2)))
struct DogfoodReportBoundaryTests {
  @Test func newestReportDateAndFirstReportFallback() throws {
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
      for day in ["2023-11-13", "2023-11-14"] {
        try Data("Acme report".utf8).write(to: reports.appending(path: day + ".md"))
      }
      let next = try DogfoodReportTests.run([], scratch: scratch, tools: tools, script: script)
      #expect(next.termination == .exit(0))
      Golden.forTests().check(next.stdout, "dogfood-report.md")
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

  @Test(arguments: ["logs", "list", "timeline", "schema", "sqlite", "missing", "asof"])
  func failedCollectionNeverPublishesPartialMarkdown(failure: String) throws {
    try withScratchDirectory { scratch in
      _ = try DogfoodReportTests.setup(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      let binary = shellWord(try SiltaBinary.url().path)
      switch failure {
      case "logs":
        try Data("Acme foreign malformed content".utf8).write(
          to: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
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
      _ = try DogfoodToolingTests.importStore(scratch)
      let tools = try DogfoodReportTests.tools(scratch)
      try FileManager.default.removeItem(
        at: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let result = try DogfoodReportTests.run(
        ["--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("Untagged log lines: 0"))
      #expect(result.stdout.contains("0 sessions; median 0 calls; maximum 0 calls."))
      #expect(
        result.stdout.contains("Proposals accepted: 0; dropped: 0; 14-day window expiries: 0"))
      #expect(result.stdout.contains("Inbox size and oldest item: n/a (S11)."))
    }
  }
}
