import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct DocScopedListCommandTests {
  static func run(_ args: [String], _ home: URL) throws -> CLIResult {
    try SiltaBinary.run(
      ["--ws", "acme", "doc"] + args + ["--json"], in: home,
      environment: TaskCommandTests.fixed)
  }

  static func follow(_ command: String, _ home: URL) throws -> CLIResult {
    try #require(command.hasPrefix("silta "))
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/sh"),
      ["-c", "exec " + shellWord(try SiltaBinary.url().path) + command.dropFirst(5) + " --json"],
      in: home, environment: TaskCommandTests.fixed)
  }

  static func other(_ home: URL) throws {
    let file = try DocEditCommandTests.input(home, "Other Acme knowledge.")
    let result = try DocEditCommandTests.run(
      ["zz-other"] + DocEditCommandTests.creation + ["-F", file.path], home)
    try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
  }

  static func refs(_ data: [String: Any]) throws -> [String] {
    try #require(data["entries"] as? [[String: Any]]).map { try #require($0["ref"] as? String) }
  }

  @Test func helpAndSchemaDescribeTheScopedFilter() throws {
    try withScratchDirectory { home in
      let help = try SiltaBinary.run(["doc", "ls", "--help"], in: home)
      #expect(help.termination == .exit(0))
      Golden.forTests().check(help.stdout, "help-doc-ls.txt")
      let data = try GuideContractTests.data(
        SiltaBinary.run(["schema", "doc", "ls", "--json"], in: home))
      let commands = try #require(data["commands"] as? [[String: Any]])
      let arguments = try #require(commands.first?["arguments"] as? [[String: Any]])
      let option = try #require(arguments.first { $0["names"] as? [String] == ["--doc"] })
      let json = try JSONSerialization.data(withJSONObject: option, options: [.sortedKeys])
      Golden.forTests().check(
        try #require(String(data: json, encoding: .utf8)) + "\n", "schema-doc-filter.json")
    }
  }

  @Test func documentFilterComposesAndPagesWithoutChangingTruth() throws {
    try withScratchDirectory { home in
      let store = try DocReadCommandTests().fixture(home)
      try AcmeDocAttachments.copyLatestRulesProposal(in: store)
      try Self.other(home)
      let before = try DocTriageCommandTests.truth(store)
      let flags = ["--about", "service:push", "--archived", "--limit", "1"]
      let first = try Self.run(["ls", "--doc", "doc:rules"] + flags, home)
      #expect(first.termination == .exit(0), "\(first.stdout)\(first.stderr)")
      guard first.termination == .exit(0) else { return }
      let data = try GuideContractTests.data(first)
      #expect(try Self.refs(data) == ["doc:rules@3"] && data["total"] as? Int == 2)
      let next = try #require(data["next"] as? String)
      #expect(next.contains("--doc 'rules'") && next.contains("--about 'service:push'"))
      #expect(next.contains("--archived") && next.contains("--offset 1 --limit 1"))
      let second = try GuideContractTests.data(Self.follow(next, home))
      #expect(try Self.refs(second) == ["doc:rules@4"] && second["next"] == nil)
      #expect(try Self.run(["ls", "--doc", "rules"] + flags, home).stdout == first.stdout)
      #expect(
        try GuideContractTests.data(Self.run(["ls", "--doc", "missing"], home))["total"] as? Int
          == 0)
      #expect(try DocTriageCommandTests.truth(store) == before)
      try store.write {
        try $0.database.execute(sql: "UPDATE doc SET archived=1 WHERE slug='rules'")
      }
      #expect(
        try GuideContractTests.data(Self.run(["ls", "--doc", "rules"], home))["total"] as? Int == 0)
      #expect(
        try GuideContractTests.data(Self.run(["ls", "--doc", "rules", "--archived"], home))["total"]
          as? Int == 3)
    }
  }

  @Test(arguments: [false, true])
  func bothUnpinnedPendingRoutesReplayOnlyTheirDocument(accepted: Bool) throws {
    try withScratchDirectory { home in
      let store = try AcmeDocAttachments.make(in: home)
      try AcmeDocAttachments.attach("aa-other", to: "service", in: store)
      try Self.other(home)
      if accepted { try AcmeDocAttachments.attach("rules", to: "service", in: store) }
      for number in 1...23 {
        let file = try DocEditCommandTests.input(home, "Acme knowledge \(number).")
        let result = try Self.run(
          ["propose", "rules"] + DocEditCommandTests.creation
            + ["-F", file.path, "-m", "Share knowledge."], home)
        try #require(result.termination == .exit(0), "\(result.stdout)\(result.stderr)")
      }
      let before = try DocTriageCommandTests.truth(store)
      let shown = try GuideContractTests.data(Self.run(["show", "rules"], home))
      let text = try #require(shown["output"] as? String)
      let lines = text.components(separatedBy: "\n")
      var next =
        accepted
        ? lines.first?.components(separatedBy: "pending: ").last
        : lines.first { $0.hasPrefix("next: ") }.map { String($0.dropFirst(6)) }
      #expect(next?.contains("--doc 'rules'") == true)
      var refs: [String] = []
      for _ in 0..<4 {
        guard let command = next else { break }
        #expect(command.contains("--doc 'rules'"))
        let page = try GuideContractTests.data(Self.follow(command, home))
        refs += try Self.refs(page)
        next = page["next"] as? String
      }
      #expect(next == nil)
      #expect(refs.count == (accepted ? 24 : 23) && refs.allSatisfy { $0.hasPrefix("doc:rules@") })
      #expect(try DocTriageCommandTests.truth(store) == before)
    }
  }

  @Test func inboxMoreIsScopedAndReplayable() throws {
    try withScratchDirectory { home in
      let store = try DocInboxCommandTests().fixture(home)
      try Self.other(home)
      let before = try DocTriageCommandTests.truth(store)
      let data = try GuideContractTests.data(
        SiltaBinary.run(
          ["--ws", "acme", "inbox", "--for", "me", "--json"], in: home,
          environment: TaskCommandTests.fixed))
      let items = try #require(data["items"] as? [[String: Any]])
      let group = try #require(items.compactMap { $0["doc_proposal"] as? [String: Any] }.first)
      let command = try #require(group["next"] as? String)
      #expect(command.contains("--doc 'rules'") && command.contains("--offset 0 --limit 20"))
      let page = try GuideContractTests.data(Self.follow(command, home))
      #expect(try Self.refs(page).allSatisfy { $0.hasPrefix("doc:rules@") })
      #expect(try DocTriageCommandTests.truth(store) == before)
    }
  }

  @Test(arguments: [false, true], ["rules@1", "doc:rules@1"])
  func pinnedFilterIsInvalidBeforeWorkspaceAccess(explicit: Bool, ref: String) throws {
    try withScratchDirectory { home in
      let result = try SiltaBinary.run(
        (explicit ? ["--ws", "acme"] : [])
          + ["doc", "ls", "--doc", ref, "--json"], in: home, environment: TaskCommandTests.fixed)
      #expect(result.termination == .exit(1))
      #expect(try DocEditCommandTests.error(result)["code"] as? String == "invalid")
      #expect(
        !FileManager.default.fileExists(atPath: home.appending(path: "silta-home/silta.db").path))
    }
  }
}
