import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct BriefDocsLogTests {
  @Test func countsOnlyDocumentPreviewsRetainedByTheBrief() throws {
    try withScratchDirectory { scratch in
      let tools = try DogfoodReportTests.tools(scratch)
      let repo = try WhereCommandTests().setup(scratch)
      try WhereCommandTests().git(["checkout", "-q", "api"], repo, scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          ["--ws", "acme"] + args, in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      }
      #expect(try run(["brief"]).termination == .exit(0))
      let emptyLog = try lastLog(scratch)
      #expect(emptyLog["docs_shown"] as? Int == 0)
      #expect(emptyLog["docs_counted"] as? Int == 0)
      try seedDocuments(in: scratch, using: run)
      let full = try run(["brief"])
      #expect(full.stdout.contains("doc:app-rules") && full.stdout.contains("doc:interface"))
      let fullLog = try lastLog(scratch)
      #expect(fullLog["docs_shown"] as? Int == 3)
      #expect(fullLog["docs_counted"] as? Int == 0)
      try checkLogContract(fullLog)
      for flags in [["--budget", "1"], ["--short"], ["--hook"]] {
        let result = try run(["brief"] + flags)
        #expect(result.termination == .exit(0))
        #expect(
          !result.stdout.contains("doc:app-rules") && !result.stdout.contains("doc:interface"))
        let entry = try lastLog(scratch)
        #expect(entry["docs_shown"] as? Int == 0)
        #expect(entry["docs_counted"] as? Int == (flags == ["--budget", "1"] ? 0 : 3))
      }
      let hook = try AgentsHookTests.hook(
        shellWord(try SiltaBinary.url().path) + " --ws acme agents session-start",
        payload: #"{"session_id":"acme"}"#, in: scratch,
        environment: [
          "SILTA_NOW": "2023-11-14T22:13:20.000Z",
          "CLAUDE_ENV_FILE": scratch.appending(path: "claude-env").path,
        ], cwd: repo)
      #expect(hook.termination == .exit(0) && hook.stdout.contains("docs: 2"))
      #expect(try lastLog(scratch)["docs_shown"] as? Int == 0)
      #expect(try lastLog(scratch)["docs_counted"] as? Int == 3)
      let report = try DogfoodReportTests.run(
        ["--ws", "acme", "--since", "2023-11-14"], scratch: scratch, tools: tools)
      try #require(report.termination == .exit(0), "\(report.stderr)")
      let text = try String(
        contentsOf: scratch.appending(path: "silta-home/reports/acme/2023-11-30.md"),
        encoding: .utf8)
      #expect(text.contains("Observed brief document pointers: 9 counted documents."))
      #expect(try run(["brief", "--task", "AC-999"]).termination == .exit(2))
      #expect(try lastLog(scratch)["docs_shown"] == nil)
      #expect(try lastLog(scratch)["docs_counted"] == nil)
    }
  }

  private func checkLogContract(_ entry: [String: Any]) throws {
    let contract = entry.filter {
      ["command", "docs_shown", "docs_counted", "workspace"].contains($0.key)
    }
    let encoded = try JSONSerialization.data(withJSONObject: contract, options: [.sortedKeys])
    Golden.forTests().check(
      try #require(String(data: encoded, encoding: .utf8)) + "\n", "brief-docs-log.json")
  }

  private func seedDocuments(in scratch: URL, using run: ([String]) throws -> CLIResult) throws {
    let config = scratch.appending(path: "workspace.yaml")
    try """
    workspace: {slug: acme, name: Acme, task_prefix: AC}
    repos: [{slug: platform}]
    apps:
      - {slug: api, repo: platform, ref: origin/api}
      - {slug: portal, repo: platform, ref: origin/portal}
    edges: [{from: api, to: portal, kind: http, summary: Acme interface}]
    """.write(to: config, atomically: true, encoding: .utf8)
    let updated = try run(["ws", "edit", "-F", config.path, "--approved", "Set up Acme map"])
    try #require(updated.termination == .exit(0), "\(updated.stderr)")
    let body = scratch.appending(path: "body.md")
    try "Keep the Acme fallback explicit.\n".write(to: body, atomically: true, encoding: .utf8)
    for (slug, about) in [
      ("app-rules", "app:api"), ("fallback", "app:api"), ("interface", "edge:api/portal/http"),
    ] {
      try #require(
        run([
          "doc", "edit", slug, "--title", "Acme rules", "--about", about,
          "-F", body.path, "--approved", "Share the Acme rule",
        ]).termination == .exit(0))
    }
  }

  private func lastLog(_ scratch: URL) throws -> [String: Any] {
    let log = try String(
      contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
    let line = try #require(log.split(separator: "\n").last)
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  }
}
