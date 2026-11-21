import Foundation
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct DatabaseLocationCommandTests {
  @Test(arguments: [true, false])
  func danglingStoreNeverLooksLikeAnEmptyWorkspace(absolute: Bool) throws {
    try withScratchDirectory { scratch in
      let fm = FileManager.default
      let repo = scratch.appending(path: "checkout")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let home = scratch.appending(path: "silta-home")
      try fm.createDirectory(at: home, withIntermediateDirectories: true)
      let target = "Acme-private-target.db"
      let link = home.appending(path: "silta.db")
      let missing = home.appending(path: target)
      let destination = absolute ? missing.path : target
      try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)

      let hook = try SiltaBinary.run(
        ["brief", "--hook"], in: scratch, cwd: repo, environment: TaskCommandTests.fixed)
      #expect(hook == CLIResult(termination: .exit(0), stdout: "", stderr: ""))
      let daily = home.appending(path: "log/2023-11-14.jsonl")
      let text = try String(contentsOf: daily, encoding: .utf8)
      let lines = text.split(separator: "\n")
      let row = try GuideContractTests.object(String(try #require(lines.first)))
      #expect(lines.count == 1)
      #expect(row["command"] as? String == "silta brief")
      #expect(row["exit_code"] as? Int == 0)
      #expect(!text.contains(target) && !text.contains("hook_failed"))
      #expect(row["error_code"] as? String == "env")

      let commands = [["where"], ["brief"], ["ws", "ls"], ["--ws", "acme", "ws", "show"]]
      var next: [String] = []
      for args in commands {
        let result = try SiltaBinary.run(
          args + ["--json"], in: scratch, cwd: repo, environment: TaskCommandTests.fixed)
        let error = try TaskStateCommandTests.error(result)
        #expect(!result.stdout.contains(target) && !result.stderr.contains(target))
        #expect(result.termination == .exit(9))
        #expect(error["code"] as? String == "env")
        next = try #require(error["next"] as? [String])
        #expect(next == ["silta doctor"])
      }
      let hint = try #require(next.first)
      let diagnosis = try FirstWorkspaceCommandTests.replay(
        hint, in: scratch, cwd: repo, json: true)
      #expect(diagnosis.termination == .exit(9))
      #expect(diagnosis.stdout.contains("database.writable"))
      #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == destination)
      #expect(!fm.fileExists(atPath: missing.path))
    }
  }

  @Test func workspaceRemovalDistinguishesDanglingStorageFromAMissingWorkspace() throws {
    try withScratchDirectory { scratch in
      let home = scratch.appending(path: "silta-home")
      let fm = FileManager.default
      try fm.createDirectory(at: home, withIntermediateDirectories: true)
      let link = home.appending(path: "silta.db")
      try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "Acme-hidden-target.db")
      let preview = try SiltaBinary.run(
        ["ws", "rm", "acme", "--dry-run", "--json"], in: scratch,
        environment: TaskCommandTests.fixed)
      let error = try TaskStateCommandTests.error(preview)
      withKnownIssue("Removal currently reports an unknown workspace instead of a broken store.") {
        #expect(preview.termination == .exit(9))
        #expect(error["code"] as? String == "env")
        #expect(error["next"] as? [String] == ["silta doctor"])
      }
      #expect(!preview.stdout.contains("Acme-hidden-target"))
      #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "Acme-hidden-target.db")
    }
  }

  @Test func workspaceListCanReadAnExistingLinkedStore() throws {
    try withScratchDirectory { scratch in
      let physical = scratch.appending(path: "physical")
      let fm = FileManager.default
      try fm.createDirectory(at: physical, withIntermediateDirectories: true)
      let store = try TaskCommandTests.setup(physical)
      let home = scratch.appending(path: "silta-home")
      try fm.createDirectory(at: home, withIntermediateDirectories: true)
      try fm.createSymbolicLink(
        at: home.appending(path: "silta.db"), withDestinationURL: URL(filePath: store.path))
      let listed = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch)
      #expect(listed.termination == .exit(0))
      let rows = try TaskStateCommandTests.data(listed)["workspaces"] as? [[String: Any]]
      #expect(rows?.count == 1)
      #expect(rows?.first?["slug"] as? String == "acme")
    }
  }
}
