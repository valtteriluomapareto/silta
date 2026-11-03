import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TaskPlanDeleteRegressionTests {
  @Test(arguments: [":(literal)plan.md", "plan[1].md", ":(glob)plan[ab].md"])
  func trackedPathspecNamesSurviveWithoutWrites(name: String) throws {
    try withKnownIssue("Confirmed tracked pathspec defect", isIntermittent: true) { () throws -> Void in
      try withScratchDirectory { scratch in
        let store = try TaskCommandTests.setup(scratch)
        let repo = scratch.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(try SiltaBinary.runProcess(URL(filePath: "/usr/bin/git"), ["init", "-q"], in: scratch, cwd: repo).termination == .exit(0))
        let file = repo.appending(path: name)
        try "# Acme\n- Preserve\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try SiltaBinary.runProcess(URL(filePath: "/usr/bin/git"), ["--literal-pathspecs", "add", "--", name], in: scratch, cwd: repo).termination == .exit(0))
        let result = try SiltaBinary.run(["task", "from-plan", file.path, "--delete", "--json"], in: scratch, cwd: repo, environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
      }
    }
  }

  @Test(arguments: [".git", "admin", "alias"])
  func gitAdministrativeSourcesSurviveWithoutWrites(mode: String) throws {
    try withKnownIssue("Confirmed task safety defect") { () throws -> Void in
      try withScratchDirectory { scratch in
        let store = try TaskCommandTests.setup(scratch)
        let repo = scratch.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let args = ["init", "-q"] + (mode == "admin" ? ["--separate-git-dir", repo.appending(path: "admin").path] : [])
        #expect(try SiltaBinary.runProcess(URL(filePath: "/usr/bin/git"), args, in: scratch, cwd: repo).termination == .exit(0))
        var source = repo.appending(path: mode == "admin" ? "admin" : ".git", directoryHint: .isDirectory)
        if mode == "alias" {
          let alias = repo.appending(path: "alias", directoryHint: .isDirectory)
          try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
          source = alias
        }
        let file = source.appending(path: "plan.md")
        try "# Acme\n- Preserve metadata\n".write(to: file, atomically: true, encoding: .utf8)
        let result = try SiltaBinary.run(["task", "from-plan", file.path, "--delete", "--json"], in: scratch, cwd: repo, environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM task") } == 0)
      }
    }
  }
}

extension TaskPlanDeleteRegressionTests {
  @Test func earlyHumanOnlyRetryPreservesRevisionWithoutReadingTheFile() throws {
    try withKnownIssue("Confirmed task safety defect") { () throws -> Void in
      try withScratchDirectory { scratch in
        let result = try SiltaBinary.run(
          ["--ws", "acme", "task", "plan", "AC-1", "--if-rev", "1", "--allow-secret", "-F", "/absent", "--json"],
          in: scratch, environment: TaskCommandTests.actor)
        #expect(result.termination == .exit(3))
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["next"] as? [String] == ["silta --ws 'acme' task plan 'AC-1' --if-rev 1 --allow-secret -F <file>"])
        #expect(!FileManager.default.fileExists(atPath: scratch.appending(path: "silta-home/silta.db").path))
      }
    }
  }
}
