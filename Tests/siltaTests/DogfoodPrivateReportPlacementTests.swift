import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

/// Where `dogfood-report.sh --ws <slug>` may write: never inside a git work tree, and
/// in a folder every valid workspace slug can name.
@Suite(.timeLimit(.minutes(2)))
struct DogfoodPrivateReportPlacementTests {
  typealias Report = DogfoodReportTests

  static func script() -> String {
    Report.root.appending(path: "scripts/dogfood-report.sh").path
  }

  /// Runs the report with `environment` layered over the fixture's.
  static func run(_ args: [String], scratch: URL, tools: URL, environment: [String: String])
    throws -> CLIResult
  {
    try SiltaBinary.runProcess(
      URL(filePath: "/bin/bash"), [script()] + args, in: scratch,
      environment: [
        "PATH": tools.path + ":/usr/bin:/bin", "SILTA_ACTOR": Report.actor,
        "SILTA_NOW": "2023-11-30T00:00:00.000Z",
      ].merging(environment) { $1 })
  }

  static func reports(under folder: URL) -> [String] {
    let walker = FileManager.default.enumerator(atPath: folder.path)
    var found: [String] = []
    while let relative = walker?.nextObject() as? String {
      if relative.hasSuffix(".md") { found.append(relative) }
    }
    return found
  }

  /// Moves the fixture's home to `home` and returns the work tree that now holds it.
  static func placeHome(_ layout: String, scratch: URL) throws -> (
    repo: URL, environment: [String: String]
  ) {
    let fm = FileManager.default
    let fixture = scratch.appending(path: "silta-home")
    switch layout {
    case "ignored-state":
      let repo = scratch.appending(path: "acme-repo")
      try fm.createDirectory(at: repo, withIntermediateDirectories: true)
      _ = try DogfoodInstallTests.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
      try Data("*.db*\n*.lock\nlog/\nbackups/\n".utf8).write(to: repo.appending(path: ".gitignore"))
      try fm.moveItem(at: fixture, to: repo.appending(path: ".silta"))
      return (repo, ["SILTA_HOME": repo.appending(path: ".silta").path])
    case "home-is-a-repo":
      let repo = scratch.appending(path: "home")
      try fm.createDirectory(at: repo, withIntermediateDirectories: true)
      _ = try DogfoodInstallTests.git(["init", "-q", "-b", "main"], in: scratch, cwd: repo)
      try fm.moveItem(at: fixture, to: repo.appending(path: ".silta"))
      return (repo, ["SILTA_HOME": ""])
    case "linked-worktree":
      let repo = scratch.appending(path: "acme-worktree")
      try fm.createDirectory(at: repo, withIntermediateDirectories: true)
      try Data("gitdir: /nowhere/acme/.git/worktrees/x\n".utf8).write(
        to: repo.appending(path: ".git"))
      try fm.createDirectory(at: repo.appending(path: "state"), withIntermediateDirectories: true)
      try fm.moveItem(at: fixture, to: repo.appending(path: "state/silta"))
      return (repo, ["SILTA_HOME": repo.appending(path: "state/silta").path])
    case "linked-home":
      let repo = scratch.appending(path: "acme-repo")
      try fm.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      try fm.moveItem(at: fixture, to: repo.appending(path: ".silta"))
      let link = scratch.appending(path: "silta-link")
      try fm.createSymbolicLink(at: link, withDestinationURL: repo.appending(path: ".silta"))
      return (repo, ["SILTA_HOME": link.path])
    default:
      let repo = scratch.appending(path: "acme-repo")
      try fm.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
      try fm.createDirectory(
        at: fixture.appending(path: "reports"), withIntermediateDirectories: true)
      try fm.createSymbolicLink(
        at: fixture.appending(path: "reports/silta"), withDestinationURL: repo)
      return (repo, [:])
    }
  }

  @Test(arguments: [
    "ignored-state", "home-is-a-repo", "linked-worktree", "linked-home", "linked-reports",
  ])
  func reportIsNeverWrittenInsideAWorkTree(layout: String) throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let placed = try Self.placeHome(layout, scratch: scratch)
      let result = try Self.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools,
        environment: placed.environment)
      #expect(result.termination == .exit(1) && result.stdout.isEmpty)
      #expect(result.stderr.contains("inside the git work tree " + placed.repo.path))
      #expect(Self.reports(under: scratch).isEmpty)
      if layout == "ignored-state" {
        let status = try DogfoodInstallTests.git(
          ["status", "--short", "--untracked-files=all"], in: scratch, cwd: placed.repo)
        #expect(status == "?? .gitignore", "\(status)")
      }
    }
  }

  @Test func aHomeOutsideEveryWorkTreeStillWrites() throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let result = try Self.run(
        ["--ws", "silta", "--since", "2023-11-14"], scratch: scratch, tools: tools,
        environment: [:])
      #expect(result.termination == .exit(0))
      #expect(Self.reports(under: scratch) == ["silta-home/reports/silta/2023-11-30.md"])
    }
  }

  @Test(arguments: ["9", "9a_B-c"])
  func digitLeadingSlugsAreValid(slug: String) throws {
    try withScratchDirectory { scratch in
      let store = try Report.setup(scratch)
      try store.write {
        try $0.database.execute(
          sql: "INSERT INTO workspace(uid,slug,name,task_prefix) VALUES(?,?,'Acme digits','DG')",
          arguments: ["acme-" + slug, slug])
      }
      let tools = try Report.tools(scratch)
      let result = try Report.run(
        ["--ws", slug, "--since", "2023-11-14"], scratch: scratch, tools: tools)
      #expect(result.termination == .exit(0))
      #expect(result.stdout.hasSuffix("/silta-home/reports/\(slug)/2023-11-30.md\n"))
    }
  }

  /// Slugs past the 255-byte file name limit get a shortened folder that still names the
  /// workspace uniquely; `.` never occurs in a slug, so it cannot collide with one.
  @Test func slugsTooLongForAFolderNameStillGetTheirOwnReport() throws {
    try withScratchDirectory { scratch in
      _ = try Report.setup(scratch)
      let tools = try Report.tools(scratch)
      let stem = String(repeating: "a", count: 299)
      var folders: [String] = []
      for (index, last) in ["b", "c"].enumerated() {
        let repo = scratch.appending(path: "long-repo-\(index)")
        try InitCommandTests.makeRepo(repo, in: scratch)
        let scan = try SiltaBinary.run(
          ["init", "--scan", repo.path, "--slug", stem + last, "--prefix", "L\(index)"],
          in: scratch)
        #expect(scan.termination == .exit(0))
        let report = try Report.run(
          ["--ws", stem + last, "--since", "2023-11-14"], scratch: scratch, tools: tools)
        #expect(report.termination == .exit(0) && report.stderr.isEmpty)
        let path = report.stdout.trimmingCharacters(in: .newlines)
        let folder = URL(filePath: path).deletingLastPathComponent().lastPathComponent
        #expect(folder.utf8.count <= 255)
        #expect(folder.wholeMatch(of: /a{200}\.[0-9a-f]{16}/) != nil)
        #expect(path.hasSuffix("/2023-11-30.md"))
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains(stem + last))
        let again = try Report.run(["--ws", stem + last], scratch: scratch, tools: tools)
        #expect(again.termination == .exit(1) && again.stderr.contains(path + " already exists"))
        folders.append(folder)
      }
      #expect(Set(folders).count == 2)
    }
  }
}
