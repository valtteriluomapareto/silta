import Foundation
import GRDB
import SiltaTestSupport
import Testing

extension DogfoodReportTests {
  @Test func commandProducedDecisionsAndBriefExposureAreReported() throws {
    try withScratchDirectory { scratch in
      let repo = try WhereCommandTests().setup(scratch)
      try WhereCommandTests().git(["checkout", "-q", "api"], repo, scratch)
      let tools = try Self.tools(scratch)
      try FileManager.default.removeItem(
        at: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"))
      let body = scratch.appending(path: "body.md")
      try "Keep Acme fallback explicit.\n".write(to: body, atomically: true, encoding: .utf8)
      func command(_ args: [String], at time: String = "2023-11-14T00:00:00.000Z") throws {
        let result = try SiltaBinary.run(
          ["--ws", "acme"] + args, in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": time])
        try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      }
      for slug in ["accept", "reject", "pending"] {
        try command(
          [
            "doc", "propose", slug, "--title", "Rules", "--about", "app:api", "-m", "Share",
            "-F", body.path,
          ], at: slug == "accept" ? "2023-11-01T00:00:00.000Z" : "2023-11-14T00:00:00.000Z")
      }
      try command([
        "doc", "triage", "--accept", "doc:accept@1", "--reject", "doc:reject@1",
        "--approved", "Use the Acme decisions",
      ])
      try command([
        "doc", "edit", "direct", "--title", "Direct rules", "--about", "app:api", "-F", body.path,
        "--approved", "Share the Acme rules",
      ])
      try command(["brief"])
      try command(["brief", "--hook", "--task", "AC-999"])
      let result = try Self.run(
        ["--ws", "acme", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      try #require(result.termination == .exit(0), "\(result.stderr)")
      let report = try String(
        contentsOf: scratch.appending(path: "silta-home/reports/acme/2023-11-30.md"),
        encoding: .utf8)
      #expect(report.contains("Known submissions created in range: 2."))
      #expect(
        report.contains("Known decisions in range: 1 accepted; 1 rejected; acceptance rate 50%."))
      #expect(report.contains("Pending at report time: 1; crossed 14 days in range: 1."))
      #expect(report.contains("Unattributed terminal history created in range: 1"))
      #expect(report.contains("Recorded doc-triage approvals in range: 1."))
      #expect(report.contains("Observed approvals per successful batch (human + agent): 1."))
      #expect(report.contains("Observed brief document exposure: 1 agent sessions; 2 previews."))
      #expect(report.contains("Legacy brief exposure unknown: 0 calls."))
      #expect(!report.contains("Keep Acme fallback") && !report.contains("Use the Acme decisions"))
    }
  }

  @Test func genuineV6HistoryKeepsDecisionEvidenceUnknownWithoutMigrating() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "silta-home")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      let fixture = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/storage-v6.db")
      let database = home.appending(path: "silta.db")
      try FileManager.default.copyItem(at: fixture, to: database)
      let tools = try Self.tools(scratch)
      let result = try Self.run(
        ["--ws", "acme", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      try #require(result.termination == .exit(0), "\(result.stderr)")
      let report = try String(
        contentsOf: home.appending(path: "reports/acme/2023-11-30.md"), encoding: .utf8)
      #expect(
        report.contains("Known decisions in range: 0 accepted; 0 rejected; acceptance rate n/a."))
      #expect(report.contains("direct or legacy; not known proposal decisions"))
      #expect(
        try DatabaseQueue(path: database.path).read {
          try String.fetchOne($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC")
        } == "v6")
    }
  }
}
