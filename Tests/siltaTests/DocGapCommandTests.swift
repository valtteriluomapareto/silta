import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DocGapCommandTests {
  static let environment = [
    "SILTA_ACTOR": "agent:codex:acme", "SILTA_NOW": "2023-11-14T22:13:20.000Z",
  ]

  /// AC-1 claimed on api, which calls web with no doc about the edge.
  static func setup(_ scratch: URL) throws {
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    let config = try WorkspaceConfig.parse(
      """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps: [{slug: api, repo: platform, ref: main}, {slug: web, repo: platform, ref: web}]
      edges: [{from: api, to: web, kind: http-api, summary: Pages}]

      """)
    try store.write {
      try config.apply(in: $0, ids: SeededIDGenerator(seed: 1), at: Date(timeIntervalSince1970: 0))
    }
    try WorkspaceSelection.use("acme", in: store)
    let added = try SiltaBinary.run(
      ["task", "add", "Acme", "--start"], in: scratch, environment: Self.environment)
    #expect(added.termination == .exit(0))
    try store.write {
      try $0.database.execute(sql: "UPDATE task SET app_id=(SELECT id FROM app WHERE slug='api')")
    }
  }

  @Test(arguments: [false, true]) func submitPrintsLogsAndEncodesTheGap(json: Bool) throws {
    try withScratchDirectory { scratch in
      try Self.setup(scratch)
      let result = try SiltaBinary.run(
        ["task", "submit", "AC-1"] + (json ? ["--json"] : []), in: scratch,
        environment: Self.environment)
      #expect(result.termination == .exit(0))
      let message =
        "No doc or pending proposal covers edge:api/web/http-api. If this work taught something "
        + "an agent in the other app would need, tell the human or propose one: silta --ws "
        + "'acme' doc propose <slug> --title <title> --about 'edge:api/web/http-api' --task "
        + "'AC-1' -m <why> -F -; otherwise ignore this."
      if json {
        let envelope = try #require(
          try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let warnings = try #require(envelope["warnings"] as? [[String: String]])
        #expect(warnings == [["code": "doc_gap", "message": message]])
      } else {
        #expect(result.stdout == "AC-1 review\n")
        #expect(result.stderr == "warning: " + message + " [doc_gap]\n")
      }
      let logs = scratch.appending(path: "silta-home/log")
      let lines = try FileManager.default.contentsOfDirectory(
        at: logs, includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "jsonl" }
      .flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n") }
      let submit = try #require(lines.last { $0.contains("\"silta task submit\"") })
      #expect(submit.contains("\"warnings\":[\"doc_gap\"]") && !submit.contains("edge:api"))
    }
  }

  @Test func theWarningsProposeCommandIsAcceptedOnceFilledIn() throws {
    try withScratchDirectory { scratch in
      try Self.setup(scratch)
      let submitted = try SiltaBinary.run(
        ["task", "submit", "AC-1"], in: scratch, environment: Self.environment)
      let line = try #require(submitted.stderr.split(separator: "\n").first)
      let start = try #require(line.range(of: "propose one: silta "))
      let end = try #require(line.range(of: "; otherwise ignore this."))
      let command = String(line[start.upperBound..<end.lowerBound])
        .replacingOccurrences(of: "<slug>", with: "pages")
        .replacingOccurrences(of: "<title>", with: "Pages")
        .replacingOccurrences(of: "<why>", with: "Share-the-contract")
      let body = scratch.appending(path: "pages.md")
      try Data("Keep page ids stable.\n".utf8).write(to: body)
      let words = command.matches(of: /'[^']*'|\S+/).map { match in
        String(match.output).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
      }.map { $0 == "-" ? body.path : $0 }
      #expect(words.contains("-m") && words.last == body.path)
      let proposed = try SiltaBinary.run(words, in: scratch, environment: Self.environment)
      #expect(proposed.termination == .exit(0), "\(proposed.stderr)")
      let listed = try SiltaBinary.run(
        ["doc", "ls", "--about", "edge:api/web/http-api"], in: scratch,
        environment: Self.environment)
      #expect(listed.stdout.contains("doc:pages@1 [proposed]"))
    }
  }
}
