import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(2)))
struct CodeCommandTests {
  @Test func unusualNamesAndBinaryFilesHaveUsablePaths() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let names = ["café.md", "line\nbreak.md", "quote\".md"]
      for name in names {
        try Data("Unusual token\n".utf8).write(to: repo.appending(path: "apps/console/" + name))
      }
      try Data("\0Unusual token\n".utf8).write(to: repo.appending(path: "apps/console/binary"))
      try git(["add", "."], repo, scratch)
      try git(
        [
          "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm",
          "Add unusual names",
        ], repo, scratch)
      let result = try SiltaBinary.run(
        ["code", "grep", "console@HEAD", "Unusual", "--json"], in: scratch)
      let expected =
        "café.md:1:Unusual token\n" + "\"line\\nbreak.md\":1:Unusual token\n"
        + "\"quote\\\".md\":1:Unusual token\n"
      #expect(try envelope(result.stdout)["output"] as? String == expected)
      let listed = try SiltaBinary.run(["code", "ls", "console@HEAD", ".", "--json"], in: scratch)
      #expect(
        try envelope(listed.stdout)["output"] as? String
          == "README.md\nbinary\ncafé.md\n\"line\\nbreak.md\"\n\"quote\\\".md\"\n")
    }
  }

  @Test func malformedPatternsAndBrokenClonesHaveDifferentRecovery() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let invalid = try SiltaBinary.run(["code", "grep", "console", "[", "--json"], in: scratch)
      #expect(invalid.termination == .exit(1))
      #expect(invalid.stdout.contains("\"code\":\"invalid\""))
      #expect(invalid.stdout.contains("silta code grep --help"))
      try Data("broken\n".utf8).write(to: repo.appending(path: ".git/HEAD"))
      let broken = try SiltaBinary.run(["code", "ls", "console", "--json"], in: scratch)
      #expect(broken.termination == .exit(9))
      #expect(broken.stdout.contains("\"code\":\"env\""))
    }
  }

  @Test(arguments: ["blob", "commit"])
  func missingObjectIsAnEnvironmentFailure(object: String) throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let ref = object == "blob" ? "origin/portal:portal/README.md" : "origin/portal"
      let blob = try git(["rev-parse", ref], repo, scratch)
        .trimmingCharacters(in: .newlines)
      try FileManager.default.removeItem(
        at: repo.appending(path: ".git/objects/" + blob.prefix(2) + "/" + blob.dropFirst(2)))
      let result = try SiltaBinary.run(
        ["code", "show", "portal", "portal/README.md", "--json"], in: scratch)
      #expect(result.termination == .exit(9))
      #expect(result.stdout.contains("\"code\":\"env\""))
    }
  }

  @Test func readsCommittedCodeAndPreservesDirtyClone() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      try git(["config", "format.pretty", "BAD"], repo, scratch)
      try git(["config", "color.ui", "always"], repo, scratch)
      try Data("dirty\n".utf8).write(to: repo.appending(path: "README.md"))
      try Data("untracked\n".utf8).write(to: repo.appending(path: "untracked"))
      let before = try snapshot(repo, scratch)
      let sha = try git(["rev-parse", "origin/portal"], repo, scratch).trimmingCharacters(
        in: .newlines)
      let cases: [(String, ([String], String))] = [
        ("show", (["portal", "portal/README.md"], "Acme portal\n")),
        ("grep", (["console", "Acme", "--", "*.md"], "README.md:1:Acme console\n")),
        ("log", (["portal", "-n", "1"], "\(sha) Add Acme portal\n")),
        ("ls", (["console"], "README.md\n")),
      ]
      for (verb, (args, expected)) in cases {
        for json in [false, true] {
          let result = try SiltaBinary.run(
            ["--ws", "acme"] + (json ? ["--json"] : ["--quiet"]) + ["code", verb] + args,
            in: scratch)
          try #require(result.termination == .exit(0), "\(result.stderr)\(result.stdout)")
          if json {
            let data = try envelope(result.stdout)
            #expect(data["output"] as? String == expected)
            let expectedSHA =
              verb == "grep" || verb == "ls"
              ? try git(["rev-parse", "origin/api"], repo, scratch).trimmingCharacters(
                in: .newlines) : sha
            #expect(data["sha"] as? String == expectedSHA)
            Golden.forTests().check(result.stdout, "code-\(verb).json")
            #expect(result.stderr.isEmpty)
          } else {
            #expect(result.stdout.hasSuffix(expected))
            #expect(result.stderr.contains("ref_stale"))
          }
        }
      }
      #expect(try snapshot(repo, scratch) == before)
    }
  }

  @Test func refSelectionAndLineRanges() throws {
    try withScratchDirectory { scratch in
      _ = try setup(scratch)
      let override = try SiltaBinary.run(
        ["code", "show", "portal@origin/api", "api/README.md", "--json"], in: scratch)
      #expect(try envelope(override.stdout)["output"] as? String == "Acme API\n")
      let prod = try SiltaBinary.run(
        ["code", "show", "portal", "portal/README.md", "--prod", "--json"], in: scratch)
      #expect(try envelope(prod.stdout)["ref"] as? String == "origin/portal-prod")
      let lines = try SiltaBinary.run(
        ["code", "show", "portal", "portal/README.md", "--lines", "1-20", "--json"], in: scratch)
      #expect(try envelope(lines.stdout)["output"] as? String == "Acme portal\n")
      for verb in ["grep", "log"] {
        let args = ["console", "absent"]
        let result = try SiltaBinary.run(["code", verb] + args + ["--json"], in: scratch)
        #expect(try envelope(result.stdout)["output"] as? String == "")
      }
    }
  }

  @Test func refusalsAndFetchAreActionable() throws {
    try withScratchDirectory { scratch in
      let repo = try setup(scratch)
      let cases: [([String], (Int32, String))] = [
        (["show", "portal@missing", "README.md"], (2, "not_found")),
        (["show", "missing", "README.md"], (2, "not_found")),
        (["show", "console", "README.md", "--prod"], (2, "not_found")),
        (["show", "portal", "absent"], (2, "not_found")),
        (["ls", "portal", "absent"], (2, "not_found")),
        (["show", "portal@", "README.md"], (1, "invalid")),
        (["show", "portal@origin/api", "README.md", "--prod"], (1, "invalid")),
        (["show", "portal", "README.md", "--lines", "2-1"], (1, "invalid")),
        (["show", "console", "../README.md"], (1, "invalid")),
        (["show", "console", "/README.md"], (1, "invalid")),
        (["grep", "console", "Acme", "--", ":(top)*"], (1, "invalid")),
        (["grep", "console", "Acme", "--", "./:(top)*"], (1, "invalid")),
        (["grep", "console", "Acme", "--", ":(exclude)*"], (1, "invalid")),
        (["log", "console", "-n", "0"], (1, "invalid")),
      ]
      for (args, (exit, code)) in cases {
        let result = try SiltaBinary.run(["--ws", "acme", "--json", "code"] + args, in: scratch)
        #expect(result.termination == .exit(exit), "\(result.stdout)")
        #expect(result.stdout.contains("\"code\":\"\(code)\""))
        #expect(result.stdout.contains("silta"))
      }
      let fetched = try SiltaBinary.run(
        ["code", "show", "portal", "README.md", "--fetch", "--json"], in: scratch)
      #expect(fetched.termination == .exit(0))
      #expect(fetched.stdout.contains("\"warnings\":[]"))
      try git(
        ["remote", "set-url", "origin", scratch.appending(path: "missing-origin").path], repo,
        scratch)
      let failed = try SiltaBinary.run(["code", "ls", "portal", "--fetch", "--json"], in: scratch)
      #expect(failed.termination == .exit(9))
      #expect(!failed.stdout.contains("Earlier successful repos"))
      #expect(failed.stdout.contains("without --fetch"))
      #expect(
        failed.stdout.contains(
          "\"next\":[\"silta --ws 'acme' code ls 'portal'\"],\"next_by\":\"agent\""))
    }
  }

  func setup(_ scratch: URL) throws -> URL {
    let result = try AcmeFixtures.make(at: scratch.appending(path: "fixtures"))
    try #require(result.termination == .exit(0), "\(result.stderr)")
    let repo = scratch.appending(path: "fixtures/acme-platform")
    let store = DatabaseStore(
      home: scratch.appending(path: "silta-home"),
      clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
    let config = try WorkspaceConfig.parse(
      """
      workspace: {slug: acme, name: Acme, task_prefix: AC}
      repos: [{slug: platform}]
      apps:
        - {slug: portal, repo: platform, ref: origin/portal, prod_ref: origin/portal-prod}
        - {slug: console, repo: platform, ref: origin/api, subpath: apps/console}
        - {slug: star, repo: platform, ref: origin/api, subpath: "apps/con*"}
        - {slug: colon, repo: platform, ref: origin/api, subpath: ":dir"}
      """)
    try store.write { tx in
      try config.apply(
        in: tx, ids: SeededIDGenerator(seed: 1), at: Date(timeIntervalSince1970: 1_700_000_000))
      try tx.database.execute(
        sql: "INSERT INTO repo_path(repo_id,path) SELECT id,? FROM repo", arguments: [repo.path])
    }
    try WorkspaceSelection.use("acme", in: store)
    return repo
  }

  @discardableResult func git(_ args: [String], _ repo: URL, _ scratch: URL) throws
    -> String
  {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: repo)
    try #require(result.termination == .exit(0), "\(result.stderr)")
    return result.stdout
  }

  func commitAll(_ repo: URL, _ scratch: URL) throws {
    try git(["add", "."], repo, scratch)
    try git(
      [
        "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm",
        "Add Acme files",
      ], repo, scratch)
  }

  func warnings(_ text: String) throws -> [String: String] {
    let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let list = try #require(object["warnings"] as? [[String: String]])
    return Dictionary(list.map { ($0["code"] ?? "", $0["message"] ?? "") }) { first, _ in first }
  }

  private func snapshot(_ repo: URL, _ scratch: URL) throws -> [Data] {
    try [
      Data(git(["status", "--porcelain"], repo, scratch).utf8),
      Data(contentsOf: repo.appending(path: ".git/HEAD")),
      Data(contentsOf: repo.appending(path: ".git/index")),
      Data(contentsOf: repo.appending(path: "README.md")),
      Data(contentsOf: repo.appending(path: "untracked")),
    ]
  }

  func envelope(_ text: String) throws -> [String: Any] {
    let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == true, "\(text)")
    return try #require(object["data"] as? [String: Any])
  }
}
