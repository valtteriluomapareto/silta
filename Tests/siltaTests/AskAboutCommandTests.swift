import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork)
struct AskAboutCommandTests {
  let fixture = BriefCommandTests()

  @Test func briefDefaultsShortGoldensAndStaticGuide() throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.fixture.setup(scratch)
      try fixture.fixture.git(["checkout", "-q", "api"], repo, scratch)
      let guide = try SiltaBinary.run(["guide", "human"], in: scratch)
      #expect(guide.stdout.contains("If brief shows `ask_about: short`"))
      #expect(guide.stdout.contains("repository rules and human-only gates still apply"))
      for json in ["{}", #"{"ask_about":"standard"}"#] {
        try fixture.settings(json, scratch)
        Golden.forTests().check(
          fixture.normalizeBrief(try fixture.run([], repo, scratch).stdout, repo), "brief.txt")
        let data = try fixture.fixture.data(fixture.run(["--json"], repo, scratch))
        #expect((data["settings"] as? [String: String])?.isEmpty == true)
      }
      try fixture.settings(#"{"proposals":"ask","ask_about":"short"}"#, scratch)
      for suffix in ["txt", "json"] {
        let result = try fixture.run(suffix == "json" ? ["--json"] : [], repo, scratch)
        #expect(result.termination == .exit(0))
        Golden.forTests().check(
          fixture.normalizeBrief(result.stdout, repo), "brief-ask-short.\(suffix)")
      }
      for flags in [[], ["--short"]] {
        let result = try fixture.run(flags + ["--budget", "1"], repo, scratch)
        Golden.forTests().check(result.stdout, "brief-ask-short-minimum.txt")
        let data = try fixture.fixture.data(
          fixture.run(flags + ["--budget", "1", "--json"], repo, scratch))
        #expect(
          data["settings"] as? [String: String] == ["proposals": "ask", "ask_about": "short"])
      }
      #expect(try SiltaBinary.run(["--ws", "acme", "guide", "human"], in: scratch) == guide)
      let schema = try SiltaBinary.run(["schema", "brief", "--json"], in: scratch)
      #expect(schema.stdout.contains("\"ask_about\":{\"optional\":\"string\"}"))
    }
  }

  @Test(arguments: [#""future""#, "false", "null", #"{"secret":"acme-private"}"#])
  func malformedStoredGuidanceIsBoundedAndActionable(_ value: String) throws {
    try withScratchDirectory { scratch in
      let repo = try fixture.fixture.setup(scratch)
      try fixture.settings("{\"ask_about\":\(value)}", scratch)
      let result = try fixture.run(["--budget", "1", "--json"], repo, scratch)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.contains("setting_unsupported"))
      #expect(result.stdout.contains("ask_about"))
      #expect(result.stdout.contains("ws show"))
      #expect(!result.stdout.contains("acme-private"))
      let text = try fixture.run(["--budget", "1"], repo, scratch).stdout
      #expect(text.contains("settings unsupported: ask_about (ask the human)"))
      let root = try GuideContractTests.object(result.stdout)
      let warnings = try #require(root["warnings"] as? [[String: String]])
      #expect(warnings.count == 1)
      #expect(try #require(warnings.first?["message"]).count < 300)
    }
  }

  @Test func workspaceEditIsHumanOnlyValidatedAndRecorded() throws {
    try withScratchDirectory { scratch in
      let store = fixture.store(scratch)
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES('acme','acme','Acme','AC')")
      }
      let file = scratch.appending(path: "workspace.yaml")
      let yaml =
        "workspace: {slug: acme, name: Acme, task_prefix: AC}\nsettings: {ask_about: short}\n"
      try yaml.write(to: file, atomically: true, encoding: .utf8)
      func run(_ flags: [String]) throws -> CLIResult {
        try SiltaBinary.run(
          ["--ws", "acme", "ws", "edit", "-F", file.path, "--json"] + flags,
          in: scratch, environment: ["SILTA_ACTOR": "agent:codex:acme"])
      }
      #expect(try run([]).termination == .exit(3))
      try #require(run(["--approved", "Use short guidance"]).termination == .exit(0))
      let shown = try SiltaBinary.run(["--ws", "acme", "ws", "show"], in: scratch)
      #expect(shown.stdout.contains("\"ask_about\":\"short\""))
      let before = try RestoreSupportDump.settingsAndApprovals(store)
      #expect(before == [#"{"ask_about":"short"}"#, "Use short guidance"])
      try yaml.replacingOccurrences(of: "short", with: "yes").write(
        to: file, atomically: true, encoding: .utf8)
      let invalid = try run(["--approved", "Apply Acme settings"])
      #expect(invalid.termination == .exit(1))
      #expect(invalid.stdout.contains("ask_about must be standard or short"))
      #expect(try RestoreSupportDump.settingsAndApprovals(store) == before)
    }
  }
}

private enum RestoreSupportDump {
  static func settingsAndApprovals(_ store: DatabaseStore) throws -> [String] {
    try store.read { db in
      try String.fetchAll(db, sql: "SELECT settings FROM workspace")
        + String.fetchAll(db, sql: "SELECT words FROM approval ORDER BY id")
    }
  }
}
