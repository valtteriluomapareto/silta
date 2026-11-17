import Foundation
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct BriefDocsLogTests {
  @Test func countsOnlyDocumentPreviewsRetainedByTheBrief() throws {
    try withScratchDirectory { scratch in
      let fixture = WhereCommandTests()
      let repo = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], repo, scratch)
      func run(_ args: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          ["--ws", "acme"] + args, in: scratch, cwd: repo,
          environment: ["SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z"])
      }
      func lastLog() throws -> [String: Any] {
        let log = try String(
          contentsOf: scratch.appending(path: "silta-home/log/2023-11-14.jsonl"), encoding: .utf8)
        let line = try #require(log.split(separator: "\n").last)
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      }
      #expect(try run(["brief"]).termination == .exit(0))
      let emptyLog = try lastLog()
      withKnownIssue("Successful briefs must record their rendered document count") {
        #expect(emptyLog["docs_shown"] as? Int == 0)
      }
      let config = scratch.appending(path: "workspace.yaml")
      try """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps:
        - {slug: api, repo: platform, ref: origin/api}
        - {slug: portal, repo: platform, ref: origin/portal}
      edges: [{from: api, to: portal, kind: http}]
      """.write(to: config, atomically: true, encoding: .utf8)
      try #require(
        run(["ws", "edit", "-F", config.path, "--approved", "Set up Acme map"]).termination
          == .exit(0))
      let body = scratch.appending(path: "body.md")
      try "Keep the Acme fallback explicit.\n".write(to: body, atomically: true, encoding: .utf8)
      for (slug, about) in [("app-rules", "app:api"), ("interface", "edge:api/portal/http")] {
        try #require(
          run([
            "doc", "edit", slug, "--title", "Acme rules", "--about", about,
            "-F", body.path, "--approved", "Share the Acme rule",
          ]).termination == .exit(0))
      }
      let full = try run(["brief"])
      #expect(full.stdout.contains("doc:app-rules") && full.stdout.contains("doc:interface"))
      let fullLog = try lastLog()
      withKnownIssue("Successful briefs must record their rendered document count") {
        #expect(fullLog["docs_shown"] as? Int == 2)
      }
      for flags in [["--budget", "1"], ["--hook"]] {
        let result = try run(["brief"] + flags)
        #expect(result.termination == .exit(0))
        #expect(
          !result.stdout.contains("doc:app-rules") && !result.stdout.contains("doc:interface"))
        let entry = try lastLog()
        withKnownIssue("Successful briefs must record their rendered document count") {
          #expect(entry["docs_shown"] as? Int == 0)
        }
      }
      _ = try run(["brief", "--task", "AC-999"])
      #expect(try lastLog()["docs_shown"] == nil)
    }
  }
}
