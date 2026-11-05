import Foundation
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct InitCommandTests {
  @Test func bareInitCreatesOnlyDatabaseAndPointsToHumanEdit() throws {
    try withScratchDirectory { scratch in
      for json in [false, true] {
        let result = try SiltaBinary.run(["init"] + (json ? ["--json"] : []), in: scratch)
        #expect(result.termination == .exit(0))
        Golden.forTests().check(result.stdout, json ? "init.json" : "init.txt")
        #expect(result.stderr.isEmpty)
      }
      #expect(
        FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path))
    }
  }

  @Test func fetchWithoutSelectedWorkspaceIsNotFound() throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["repo", "fetch", "--json"], in: scratch)
      #expect(result.termination == .exit(2))
      #expect(result.stdout.contains("silta ws ls"))
    }
  }
  @Test func fixtureScanFetchAndPathOnlyRescan() throws {
    try withScratchDirectory { scratch in
      let root = ScenarioRunner.repository
      let fixtures = scratch.appending(path: "acme")
      let generated = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"),
        [root.appending(path: "scripts/make-fixtures.sh").path, fixtures.path], in: scratch)
      #expect(generated.termination == .exit(0))
      let scan = try SiltaBinary.run(["init", "--scan", fixtures.path, "--json"], in: scratch)
      #expect(scan.termination == .exit(0))
      Golden.forTests().check(scan.stdout, "init-scan.json")
      let use = try SiltaBinary.run(["ws", "use", "acme"], in: scratch)
      #expect(use.termination == .exit(0))
      for json in [false, true] {
        let fetched = try SiltaBinary.run(
          ["repo", "fetch", "acme-platform"] + (json ? ["--json"] : []), in: scratch)
        #expect(fetched.termination == .exit(0))
        Golden.forTests().check(fetched.stdout, json ? "repo-fetch.json" : "repo-fetch.txt")
        #expect(fetched.stderr.isEmpty)
      }
      let again = try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch)
      #expect(again.termination == .exit(0))
      Golden.forTests().check(again.stdout, "init-scan.txt")
    }
  }

  static func git(_ args: [String], in scratch: URL, cwd: URL) throws {
    let result = try SiltaBinary.runProcess(
      URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: cwd)
    #expect(result.termination == .exit(0))
  }

  /// A scanned repo named `none` takes a free slug with a warning, and the rest of the
  /// scan still creates the workspace, because `none` means non-code work.
  @Test func scanningARepoNamedNoneRenamesItAndKeepsTheScanGoing() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "acme")
      for name in ["none", "other"] {
        let repo = root.appending(path: name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Self.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
        try Data("Acme\n".utf8).write(to: repo.appending(path: "readme"))
        try Self.git(["add", "."], in: scratch, cwd: repo)
        try Self.git(
          [
            "-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm",
            "Acme",
          ], in: scratch, cwd: repo)
        try Self.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: scratch, cwd: repo)
      }
      let scan = try SiltaBinary.run(["init", "--scan", root.path], in: scratch)
      #expect(scan.termination == .exit(0))
      #expect(scan.stderr.contains("slug_renamed"))
      #expect(scan.stderr.contains("none-repo"))
      let shown = try SiltaBinary.run(["--ws", "acme", "ws", "show"], in: scratch)
      #expect(shown.termination == .exit(0))
      #expect(shown.stdout.contains("\"slug\":\"none-repo\""))
      #expect(!shown.stdout.contains("\"slug\":\"none\""))
      let again = try SiltaBinary.run(["init", "--scan", root.path], in: scratch)
      #expect(again.termination == .exit(0))
      #expect(again.stderr.isEmpty)
    }
  }

  static func fixtures(_ scratch: URL) throws -> URL {
    let fixtures = scratch.appending(path: "acme")
    let generated = try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"),
      [ScenarioRunner.repository.appending(path: "scripts/make-fixtures.sh").path, fixtures.path],
      in: scratch)
    #expect(generated.termination == .exit(0))
    return fixtures
  }

  static func gitRepo(named name: String, in scratch: URL, parent: URL) throws -> URL {
    let repo = parent.appending(path: name)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Self.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
    try Data("Acme\n".utf8).write(to: repo.appending(path: "readme"))
    try Self.git(["add", "."], in: scratch, cwd: repo)
    try Self.git(
      ["-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm", "Acme"],
      in: scratch, cwd: repo)
    try Self.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: scratch, cwd: repo)
    return repo
  }

  @Test func chosenSlugAndPrefixNameANewWorkspace() throws {
    for json in [false, true] {
      try withScratchDirectory { scratch in
        let fixtures = try Self.fixtures(scratch)
        let scan = try SiltaBinary.run(
          ["init", "--scan", fixtures.path, "--slug", "work", "--prefix", "WK"]
            + (json ? ["--json"] : []), in: scratch)
        #expect(scan.termination == .exit(0))
        Golden.forTests().check(scan.stdout, json ? "init-scan-slug.json" : "init-scan-slug.txt")
        let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
        #expect(list.stdout.contains("\"slug\":\"work\""))
        #expect(list.stdout.contains("\"task_prefix\":\"WK\""))
      }
    }
  }

  @Test func prefixWithoutSlugKeepsTheDirectorySlug() throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      let scan = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, "--prefix", "WK", "--json"], in: scratch)
      #expect(scan.termination == .exit(0))
      Golden.forTests().check(scan.stdout, "init-scan.json")
      let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(list.stdout.contains("\"slug\":\"acme\""))
      #expect(list.stdout.contains("\"task_prefix\":\"WK\""))
    }
  }

  @Test func chosenSlugThatAlreadyExistsIsRefusedWithTheRescanCommand() throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      let first = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, "--slug", "work"], in: scratch)
      #expect(first.termination == .exit(0))
      let before = try SiltaBinary.run(["ws", "show", "work"], in: scratch)
      #expect(before.termination == .exit(0))
      for flags in [["--slug", "work"], ["--prefix", "WK"]] {
        let again = try SiltaBinary.run(
          ["init", "--scan", fixtures.path] + flags + ["--json"], in: scratch)
        #expect(again.termination == .exit(6))
        #expect(again.stdout.contains("\"code\":\"conflict\""))
        #expect(again.stdout.contains(fixtures.path))
        #expect(again.stdout.contains("--ws"))
        #expect(again.stdout.contains("work"))
        #expect(try SiltaBinary.run(["ws", "show", "work"], in: scratch).stdout == before.stdout)
      }
      let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(list.stdout.components(separatedBy: "\"slug\":\"work\"").count == 2)
    }
  }

  @Test func namingOptionsAreRefusedOnARescan() throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      let result = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, "--ws", "work", "--slug", "work", "--prefix", "WK",
         "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(result.stdout.contains("--slug"))
      #expect(result.stdout.contains("--prefix"))
      #expect(result.stdout.contains("silta init --help"))
      let list = try SiltaBinary.run(["ws", "ls"], in: scratch)
      #expect(list.stdout.contains("No workspaces"))
    }
  }

  @Test(arguments: [("--slug", "My Projects"), ("--prefix", "A_")])
  func invalidChosenNamesAreRefused(flag: String, value: String) throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      let result = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, flag, value, "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(result.stdout.contains(flag))
      let list = try SiltaBinary.run(["ws", "ls"], in: scratch)
      #expect(list.stdout.contains("No workspaces"))
    }
  }

  @Test func invalidDirectoryNamesNameTheFlagToUse() throws {
    try withScratchDirectory { scratch in
      for name in ["My Projects", ".hidden"] {
        let root = scratch.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = try SiltaBinary.run(["init", "--scan", root.path, "--json"], in: scratch)
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("\"code\":\"invalid\""))
        #expect(result.stdout.contains("--slug"))
      }
    }
  }

  @Test func aDirectoryPrefixThatIsNotValidNamesThePrefixFlag() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "a_b")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let result = try SiltaBinary.run(["init", "--scan", root.path, "--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(result.stdout.contains("--prefix"))
    }
  }

  @Test func aSingleLetterDirectoryGetsASingleLetterPrefix() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "projects")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let repo = try Self.gitRepo(named: "x", in: scratch, parent: root)
      let result = try SiltaBinary.run(["init", "--scan", repo.path, "--json"], in: scratch)
      #expect(result.termination == .exit(0))
      let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(list.stdout.contains("\"slug\":\"x\""))
      #expect(list.stdout.contains("\"task_prefix\":\"X\""))
    }
  }

}
