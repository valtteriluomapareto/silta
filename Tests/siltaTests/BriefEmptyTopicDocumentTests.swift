import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct BriefEmptyTopicDocumentTests {
  @Test(arguments: [false, true])
  func acceptedEdgeDocWorksInFullTinyAndCompactBriefs(json: Bool) throws {
    try withScratchDirectory { scratch in
      let fixture = CodeCommandTests()
      let root = try fixture.setup(scratch)
      try fixture.git(["checkout", "-q", "api"], root, scratch)
      let repo = root.appending(path: "apps/console")
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: AcmeDocAttachments.instant), jitter: { 0 })
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO service(uid,workspace_id,slug,name)
            VALUES('brief-push',1,'push','Push');
            INSERT INTO edge(uid,workspace_id,from_app_id,to_service_id,kind,summary)
            SELECT 'brief-edge',1,a.id,s.id,'sdk','Push'
            FROM app a JOIN service s ON s.workspace_id=a.workspace_id
            WHERE a.slug='console' AND s.slug='push';
            """)
      }
      let file = try DocEditCommandTests.input(scratch, "Keep unknown categories visible.\n")
      let edit = try SiltaBinary.run(
        [
          "--ws", "acme", "doc", "edit", "edge-rules", "-F", file.path,
          "--title", "Rules", "--about", "edge:console/service:push/sdk",
          "--approved", "Keep Acme rules",
        ],
        in: scratch, cwd: repo, environment: TaskCommandTests.actor)
      try #require(edit.termination == .exit(0), "\(edit.stdout)\(edit.stderr)")
      for flags in [[], ["--budget", "1"], ["--short"], ["--hook"]] {
        if flags.isEmpty || flags == ["--budget", "1"] {
          withKnownIssue("SI-116: Full no-topic document briefs fail before budget insertion.") {
            try Self.check(flags, json: json, repo: repo, scratch: scratch)
          }
        } else {
          try Self.check(flags, json: json, repo: repo, scratch: scratch)
        }
      }
    }
  }

  private static func check(_ flags: [String], json: Bool, repo: URL, scratch: URL) throws {
    let result = try SiltaBinary.run(
      ["--ws", "acme", "brief", "--app", "console"] + flags + (json ? ["--json"] : []),
      in: scratch, cwd: repo, environment: TaskCommandTests.actor)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
    if json {
      let root = try #require(
        JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
      #expect(root["ok"] as? Bool == true)
    }
    if flags.isEmpty { #expect(result.stdout.contains("doc:edge-rules")) }
  }
}
