import Darwin
import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ExportCommitTests {
  static func git(_ arguments: [String], _ scratch: URL) throws -> String {
    let result = try SiltaBinary.runProcess(URL(filePath: "/usr/bin/git"), arguments, in: scratch)
    #expect(result.termination == .exit(0), "\(arguments): \(result.stderr)")
    return result.stdout.trimmingCharacters(in: .newlines)
  }

  static func prepare(_ scratch: URL) throws {
    try ExportCommandTests.seed(scratch)
    _ = try git(["init", "-q"], scratch)
    _ = try git(["config", "user.name", "Acme"], scratch)
    _ = try git(["config", "user.email", "acme@example.invalid"], scratch)
  }

  static func run(_ scratch: URL) throws -> CLIResult {
    try SiltaBinary.run(["--ws", "acme", "export", "--to", ".", "--commit", "--json"], in: scratch)
  }

  @Test func commitsAnUnbornRepoAndAnUnchangedRetryMakesNoCommit() throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      let result = try Self.run(scratch)
      #expect(result.termination == .exit(0), "\(result.stdout)")
      let sha = try Self.git(["rev-parse", "HEAD"], scratch)
      #expect(result.stdout.contains("\"sha\":\"\(sha)\""))
      Golden.forTests().check(
        ExportCommandTests.masked(result.stdout, scratch).replacingOccurrences(
          of: sha, with: "<sha>"),
        "export-commit.json")
      let retry = try Self.run(scratch)
      #expect(retry.termination == .exit(0), "\(retry.stdout)")
      #expect(!retry.stdout.contains("\"sha\""))
      #expect(try Self.git(["rev-list", "--count", "HEAD"], scratch) == "1")
      let text = try SiltaBinary.run(
        ["--ws", "acme", "export", "--to", ".", "--commit"], in: scratch)
      Golden.forTests().check(
        ExportCommandTests.masked(text.stdout, scratch), "export-commit-unchanged.txt")
    }
  }

  @Test func unrelatedStagedFilesStayStagedAndDeletedExportFilesAreRecorded() throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      let first = try Self.run(scratch)
      #expect(first.termination == .exit(0), "\(first.stdout)")
      try Data("Acme".utf8).write(to: scratch.appending(path: "work/notes.txt"))
      _ = try Self.git(["add", "notes.txt"], scratch)
      let store = DatabaseStore(
        home: scratch.appending(path: "silta-home"),
        clock: FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000)), jitter: { 0 })
      try store.write {
        try $0.database.execute(
          sql:
            "DELETE FROM comment; DELETE FROM task_event; DELETE FROM task_plan_rev; "
            + "DELETE FROM review_request; DELETE FROM task"
        )
      }
      let result = try Self.run(scratch)
      #expect(result.termination == .exit(0), "\(result.stdout)")
      #expect(try Self.git(["diff", "--cached", "--name-only"], scratch) == "notes.txt")
      let names = try Self.git(["ls-tree", "-r", "--name-only", "HEAD"], scratch)
      #expect(!names.contains("notes.txt"))
      #expect(!names.contains("tasks/AC-1"))
    }
  }

  @Test func nonRepositoryRefusesBeforeWriting() throws {
    try withScratchDirectory { scratch in
      try ExportCommandTests.seed(scratch)
      let result = try Self.run(scratch)
      #expect(result.termination == .exit(1), "\(result.stdout)")
      Golden.forTests().check(
        ExportCommandTests.masked(result.stdout, scratch), "export-commit-nonrepo.json")
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "work/acme").path))
    }
  }

  @Test func failingHookLeavesTreeAndCanRetryWithoutResettingTheIndex() throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      let hook = scratch.appending(path: "work/.git/hooks/pre-commit")
      let script = """
        #!/bin/sh
        read value && exit 2
        [ "$GIT_TERMINAL_PROMPT" = 0 ] || exit 3
        printf verified > .git/noninteractive
        exit 1

        """
      try Data(script.utf8).write(to: hook)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
      let failed = try Self.run(scratch)
      #expect(failed.termination == .exit(9), "\(failed.stdout)")
      #expect(failed.stdout.contains("tree was written"))
      #expect(failed.stdout.contains("safe to retry"))
      #expect(
        try String(contentsOf: scratch.appending(path: "work/.git/noninteractive"), encoding: .utf8)
          == "verified")
      Golden.forTests().check(
        ExportCommandTests.masked(failed.stdout, scratch), "export-commit-failed.json")
      let before = try ExportServiceFiles.all(scratch.appending(path: "work/acme"))
      #expect(!before.isEmpty)
      try FileManager.default.removeItem(at: hook)
      let retry = try Self.run(scratch)
      #expect(retry.termination == .exit(0), "\(retry.stdout)")
      #expect(before == (try ExportServiceFiles.all(scratch.appending(path: "work/acme"))))
    }
  }

  @Test func busyRetryKeepsWorkspaceRootAndCommitFlag() throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      let descriptor = open(
        scratch.appending(path: "silta-home/export.lock").path, O_CREAT | O_RDWR, 0o600)
      #expect(descriptor >= 0)
      defer { close(descriptor) }
      #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
      let result = try SiltaBinary.run(
        ["--ws", "acme", "export", "--to", ".", "--commit", "--json"], in: scratch,
        environment: ExportCommandTests.environment)
      #expect(result.termination == .exit(5))
      #expect(result.stdout.contains("silta --ws 'acme' export --to '.' --commit"))
      Golden.forTests().check(result.stdout, "export-commit-busy.json")
      #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "work/acme").path))
    }
  }

  @Test func trackedFilesMatchingIgnoreRulesDoNotWarn() throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      #expect(try Self.run(scratch).termination == .exit(0))
      try Data("acme/\n".utf8).write(to: scratch.appending(path: "work/.gitignore"))
      let result = try Self.run(scratch)
      #expect(result.termination == .exit(0), "\(result.stdout)")
      #expect(!result.stdout.contains("export_ignored"))
    }
  }

  @Test func ignoredWarningSurvivesAFailedCommit() throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      try Data("acme/tasks/\n".utf8).write(to: scratch.appending(path: "work/.gitignore"))
      let hook = scratch.appending(path: "work/.git/hooks/pre-commit")
      try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
      let failed = try Self.run(scratch)
      #expect(failed.termination == .exit(9))
      #expect(failed.stdout.contains("export_ignored"))
      #expect(failed.stdout.contains("tree was written"))
    }
  }

  @Test(arguments: ["acme/tasks/\n", "acme/\n"])
  func ignoredFilesWarn(_ rules: String) throws {
    try withScratchDirectory { scratch in
      try Self.prepare(scratch)
      try Data(rules.utf8).write(to: scratch.appending(path: "work/.gitignore"))
      let result = try Self.run(scratch)
      #expect(result.termination == .exit(0), "\(result.stdout)")
      #expect(result.stdout.contains("export_ignored"))
      #expect(
        FileManager.default.fileExists(
          atPath: scratch.appending(path: "work/acme/manifest.json").path))
    }
  }
}
