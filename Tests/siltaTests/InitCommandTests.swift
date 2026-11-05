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

  /// Makes `repo` a clone with a main branch and an `origin/main` ref.
  static func makeRepo(_ repo: URL, in scratch: URL) throws {
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Self.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
    try Data("Acme\n".utf8).write(to: repo.appending(path: "readme"))
    try Self.git(["add", "."], in: scratch, cwd: repo)
    try Self.git(
      ["-c", "user.name=Acme", "-c", "user.email=acme@example.invalid", "commit", "-qm", "Acme"],
      in: scratch, cwd: repo)
    try Self.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: scratch, cwd: repo)
  }

  /// The first `next` command a JSON refusal printed.
  static func nextCommand(_ stdout: String) throws -> String {
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    let error = try #require(object["error"] as? [String: Any])
    let next = try #require(error["next"] as? [String])
    return try #require(next.first)
  }

  /// Runs a printed `next` through a shell, the way an agent's shell would.
  static func runNext(_ command: String, in scratch: URL) throws -> CLIResult {
    let products = try SiltaBinary.url().deletingLastPathComponent().path
    return try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"), ["-c", command], in: scratch, cwd: scratch,
      environment: ["PATH": "\(products):/usr/bin:/bin:/usr/sbin:/sbin"])
  }

  /// The wiring: both options reach the workspace row, and the slug names it.
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
        #expect(list.stdout.contains("\"name\":\"work\""))
        #expect(list.stdout.contains("\"task_prefix\":\"WK\""))
      }
    }
  }

  /// The refusal carries the scanned roots and the two ways forward. The roots are
  /// absolute paths under a random scratch directory, so the golden shows `<scratch>`.
  static func checked(_ text: String, _ name: String, scratch: URL) {
    Golden.forTests().check(
      text.replacingOccurrences(of: scratch.path, with: "<scratch>"), name)
  }

  @Test func chosenSlugThatAlreadyExistsIsRefusedWithTheRescanCommand() throws {
    try withScratchDirectory { scratch in
      _ = try Self.fixtures(scratch)
      let first = try SiltaBinary.run(
        ["init", "--scan", "acme", "--slug", "work"], in: scratch, cwd: scratch)
      #expect(first.termination == .exit(0))
      let before = try SiltaBinary.run(["ws", "show", "work"], in: scratch)
      #expect(before.termination == .exit(0))
      let again = try SiltaBinary.run(
        ["init", "--scan", "acme", "--slug", "work", "--json"], in: scratch, cwd: scratch)
      #expect(again.termination == .exit(6))
      Self.checked(again.stdout, "init-scan-slug-exists.json", scratch: scratch)
      let text = try SiltaBinary.run(
        ["init", "--scan", "acme", "--slug", "work"], in: scratch, cwd: scratch)
      #expect(text.termination == .exit(6))
      Self.checked(text.stderr, "init-scan-slug-exists.txt", scratch: scratch)
      #expect(try SiltaBinary.run(["ws", "show", "work"], in: scratch).stdout == before.stdout)
      let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(list.stdout.components(separatedBy: "\"slug\":\"work\"").count == 2)
      let rescanned = try SiltaBinary.run(
        ["init", "--scan", "acme", "--ws", "work"], in: scratch, cwd: scratch)
      #expect(rescanned.termination == .exit(0))
    }
  }

  /// `--prefix` alone cannot name an existing workspace; the refusal's first `next`
  /// rescans it, and that command works.
  @Test func prefixOnAnExistingDefaultWorkspaceIsRefused() throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      let first = try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch)
      #expect(first.termination == .exit(0))
      let again = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, "--prefix", "WK", "--json"], in: scratch)
      #expect(again.termination == .exit(6))
      let next = try Self.nextCommand(again.stdout)
      #expect(next.hasSuffix("--ws 'acme'"))
      let rescanned = try Self.runNext(next, in: scratch)
      #expect(rescanned.termination == .exit(0), "\(rescanned.stderr)")
    }
  }

  @Test(arguments: [["--slug", "work"], ["--prefix", "WK"]])
  func namingOptionsAreRefusedOnARescan(options: [String]) throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      let result = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, "--ws", "work"] + options + ["--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(result.stdout.contains("--slug"))
      #expect(result.stdout.contains("--prefix"))
      #expect(result.stdout.contains("silta init --help"))
      let list = try SiltaBinary.run(["ws", "ls"], in: scratch)
      #expect(list.stdout.contains("No workspaces"))
    }
  }

  @Test(arguments: [["--slug", "work"], ["--prefix", "WK"]])
  func namingOptionsWithoutScanAreRefused(options: [String]) throws {
    try withScratchDirectory { scratch in
      let result = try SiltaBinary.run(["init"] + options + ["--json"], in: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(result.stdout.contains("--scan"))
      #expect(result.stdout.contains("silta init --help"))
      let list = try SiltaBinary.run(["ws", "ls"], in: scratch)
      #expect(list.stdout.contains("No workspaces"))
    }
  }

  /// A directory whose name is no slug: the refusal names `--slug`, and running its
  /// `next` creates the workspace.
  @Test func anInvalidDerivedNameNamesTheFlagAndItsNextWorks() throws {
    try withScratchDirectory { scratch in
      for directory in ["My Projects", ".hidden"] {
        try Self.makeRepo(scratch.appending(path: directory).appending(path: "acme"), in: scratch)
        let result = try SiltaBinary.run(
          ["init", "--scan", directory, "--json"], in: scratch, cwd: scratch)
        #expect(result.termination == .exit(1))
        #expect(result.stdout.contains("\"code\":\"invalid\""))
        #expect(result.stdout.contains("--slug"))
        #expect(result.stdout.contains(directory))
      }
      Self.checked(
        try SiltaBinary.run(["init", "--scan", "My Projects", "--json"], in: scratch, cwd: scratch)
          .stdout, "init-scan-invalid-slug.json", scratch: scratch)
      Self.checked(
        try SiltaBinary.run(["init", "--scan", "My Projects"], in: scratch, cwd: scratch).stderr,
        "init-scan-invalid-slug.txt", scratch: scratch)
      let refused = try SiltaBinary.run(
        ["init", "--scan", "My Projects", "--json"], in: scratch, cwd: scratch)
      let next = try Self.nextCommand(refused.stdout)
      let fixed = try Self.runNext(
        next.replacingOccurrences(of: "<slug>", with: "my-projects"), in: scratch)
      #expect(fixed.termination == .exit(0))
      let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(list.stdout.contains("\"slug\":\"my-projects\""))
    }
  }

  /// A repo directory whose name is no slug: the refusal names the clone, and running
  /// its `ask human: mv` renames the directory so the rescan succeeds.
  @Test func aRepoDirectoryNameRefusalGivesAMvThatFixesIt() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "root")
      let repo = root.appending(path: "My Projects")
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
      let refused = try SiltaBinary.run(["init", "--scan", root.path], in: scratch)
      #expect(refused.termination == .exit(1))
      #expect(refused.stderr.contains("Repo directory \"My Projects\" is not a valid repo slug"))
      let line = try #require(
        refused.stderr.split(separator: "\n").first { $0.hasPrefix("ask human: mv ") })
      let command = line.dropFirst("ask human: ".count)
      let paths = command.split(separator: "'").map(String.init).filter { $0.hasPrefix("/") }
      #expect(paths.count == 2)
      #expect(paths.allSatisfy { $0.hasPrefix(scratch.path) })
      let moved = try SiltaBinary.runProcess(
        URL(filePath: "/bin/bash"), ["-c", String(command)], in: scratch)
      #expect(moved.termination == .exit(0))
      let rescanned = try SiltaBinary.run(["init", "--scan", root.path], in: scratch)
      #expect(rescanned.termination == .exit(0))
      let shown = try SiltaBinary.run(["--ws", "root", "ws", "show"], in: scratch)
      #expect(shown.stdout.contains("\"slug\":\"my-projects\""))
    }
  }

  /// A directory whose prefix is no prefix: the refusal names `--prefix`, and running
  /// its `next` keeps the directory's slug.
  @Test func aDirectoryPrefixThatIsNotValidNamesThePrefixFlag() throws {
    try withScratchDirectory { scratch in
      try FileManager.default.createDirectory(
        at: scratch.appending(path: "a_b"), withIntermediateDirectories: true)
      let result = try SiltaBinary.run(
        ["init", "--scan", "a_b", "--json"], in: scratch, cwd: scratch)
      #expect(result.termination == .exit(1))
      #expect(result.stdout.contains("\"code\":\"invalid\""))
      #expect(result.stdout.contains("--prefix"))
      let fixed = try SiltaBinary.run(
        ["init", "--scan", "a_b", "--prefix", "AB"], in: scratch, cwd: scratch)
      #expect(fixed.termination == .exit(0))
      let list = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(list.stdout.contains("\"slug\":\"a_b\""))
      #expect(list.stdout.contains("\"task_prefix\":\"AB\""))
    }
  }

  /// A scan root that is itself a clone with an unusable name: the first `next`
  /// renames it, the second scans the renamed path, and both stay under the scratch
  /// directory.
  @Test func aRepoRootRefusalRenamesItThenScansTheNewPath() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "My Projects")
      try Self.makeRepo(root, in: scratch)
      let refused = try SiltaBinary.run(["init", "--scan", root.path], in: scratch)
      #expect(refused.termination == .exit(1))
      #expect(refused.stderr.contains("Repo directory \"My Projects\""))
      let commands = refused.stderr.split(separator: "\n")
        .filter { $0.hasPrefix("ask human: ") }
        .map { String($0.dropFirst("ask human: ".count)) }
      #expect(commands.count == 2)
      let rename = try #require(commands.first)
      #expect(rename.hasPrefix("mv "))
      let paths = rename.split(separator: "'").map(String.init).filter { $0.hasPrefix("/") }
      #expect(paths.count == 2)
      #expect(paths.allSatisfy { $0.hasPrefix(scratch.path) })
      let moved = try Self.runNext(rename, in: scratch)
      #expect(moved.termination == .exit(0), "\(moved.stderr)")
      let rescanned = try Self.runNext(try #require(commands.last), in: scratch)
      #expect(rescanned.termination == .exit(0), "\(rescanned.stderr)")
      let shown = try SiltaBinary.run(["ws", "show", "my-projects", "--json"], in: scratch)
      #expect(shown.termination == .exit(0))
      #expect(shown.stdout.contains("\"slug\":\"my-projects\""))
    }
  }

  /// Each naming refusal keeps the options already given, so running its first `next`
  /// lands on the workspace the caller asked for.
  @Test func everyNamingRefusalsNextKeepsTheChosenSlug() throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      #expect(try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch)
        .termination == .exit(0))
      let cases: [
        (
          arguments: [String], keeps: String, placeholder: String, replacement: String,
          created: String, prefix: String, exit: Int32
        )
      ] = [
        (["--slug", "acorn"], "--slug acorn", "<prefix>", "WK", "acorn", "WK", 6),
        (["--slug", "bad-slug", "--prefix", "A_"], "--slug bad-slug", "<prefix>", "WM",
          "bad-slug", "WM", 1),
        (["--slug", "My Projects", "--prefix", "WX"], "--prefix WX", "<slug>", "fine", "fine",
          "WX", 1),
        (["--slug", "acme", "--prefix", "WZ"], "--prefix WZ", "<another-slug>", "other", "other",
          "WZ", 6),
      ]
      for (index, testCase) in cases.enumerated() {
        let root = scratch.appending(path: "refusal-\(index)")
        try Self.makeRepo(root.appending(path: "api"), in: scratch)
        let refused = try SiltaBinary.run(
          ["init", "--scan", root.path, "--json"] + testCase.arguments, in: scratch)
        #expect(refused.termination == .exit(testCase.exit), "\(testCase.arguments)")
        let next = try Self.nextCommand(refused.stdout)
        #expect(next.contains(testCase.keeps), "\(testCase.arguments): \(next)")
        let fixed = try Self.runNext(
          next.replacingOccurrences(of: testCase.placeholder, with: testCase.replacement),
          in: scratch)
        #expect(fixed.termination == .exit(0), "\(testCase.arguments): \(fixed.stderr)")
        let shown = try SiltaBinary.run(
          ["ws", "show", testCase.created, "--json"], in: scratch)
        #expect(shown.termination == .exit(0), "\(testCase.arguments)")
        #expect(shown.stdout.contains("\"task_prefix\":\"\(testCase.prefix)\""))
      }
    }
  }

  /// The path-conflict refusal's `next` rescans the holding workspace, and it works.
  @Test func theRepoPathRefusalNamesARescanThatWorks() throws {
    try withScratchDirectory { scratch in
      let fixtures = try Self.fixtures(scratch)
      #expect(try SiltaBinary.run(["init", "--scan", fixtures.path], in: scratch)
        .termination == .exit(0))
      let refused = try SiltaBinary.run(
        ["init", "--scan", fixtures.path, "--slug", "other", "--json"], in: scratch)
      #expect(refused.termination == .exit(6))
      let next = try Self.nextCommand(refused.stdout)
      #expect(next.hasPrefix("silta --ws 'acme' init --scan "))
      let rescanned = try Self.runNext(next, in: scratch)
      #expect(rescanned.termination == .exit(0), "\(rescanned.stderr)")
    }
  }

  @Test func initHelpSaysAScanMatchesTheWorkspaceWithoutRegardToCase() throws {
    try withScratchDirectory { scratch in
      let help = try SiltaBinary.run(["init", "--help"], in: scratch)
      #expect(help.termination == .exit(0))
      #expect(help.stdout.contains("without regard to case"))
    }
  }
}
