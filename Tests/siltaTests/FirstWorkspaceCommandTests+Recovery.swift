import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

extension FirstWorkspaceCommandTests {
  @Test(arguments: [("Acme Console", "acme-console"), ("x-api", "x-api")])
  func firstScanHintCarriesValidNamingOptions(directory: String, workspace: String) throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: directory)
      try InitCommandTests.makeRepo(repo, in: scratch)
      let listed = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch, cwd: repo)
      let data = try TaskStateRegressionTests.data(listed)
      let next = try #require((data["next"] as? [String])?.first)
      let result = try Self.replay(next, in: scratch, cwd: repo, json: true)
      let payload = try GuideContractTests.object(result.stdout)["data"] as? [String: Any]
      withKnownIssue("#260: first scan cannot derive every slug or prefix") {
        #expect(result.termination == .exit(0))
        #expect(payload?["workspace"] as? String == workspace)
      }
    }
  }

  @Test func staleOriginKeepsItsRepoIdentityWhenAnotherRepoHasTheCloneName() throws {
    try withScratchDirectory { scratch in
      let root = scratch.appending(path: "original/acme")
      let original = root.appending(path: "platform")
      let other = root.appending(path: "renamed")
      try InitCommandTests.makeRepo(original, in: scratch)
      try InitCommandTests.makeRepo(other, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", Self.origin], in: scratch, cwd: original)
      try InitCommandTests.git(
        ["remote", "add", "origin", "https://example.invalid/acme/other.git"],
        in: scratch, cwd: other)
      let first = try SiltaBinary.run(["init", "--scan", "."], in: scratch, cwd: root)
      try #require(first.termination == .exit(0))
      let newRoot = scratch.appending(path: "moved/acme")
      try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
      let moved = newRoot.appending(path: "renamed")
      try FileManager.default.moveItem(at: original, to: moved)
      let result = try SiltaBinary.run(
        ["init", "--scan", ".", "--json"], in: scratch, cwd: newRoot)
      let receipt = try TaskStateRegressionTests.data(result)
      let located = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: moved)
      let untouched = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: other)
      let movedData = try GuideContractTests.object(located.stdout)["data"] as? [String: Any]
      let otherData = try GuideContractTests.object(untouched.stdout)["data"] as? [String: Any]
      withKnownIssue("#260: the scan write discards the repo identity selected by origin") {
        #expect(receipt["repositories"] as? [String] == ["platform"])
        #expect(movedData?["repo"] as? String == "platform")
        #expect(untouched.termination == .exit(0))
        #expect(otherData?["repo"] as? String == "renamed")
      }
    }
  }

  @Test func relativeOriginPermitsInspectionAndAnExplicitRepoSlugMatch() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(
        ["remote", "add", "origin", "../acme-upstream.git"], in: scratch, cwd: repo)
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'acme-platform',id,'platform','../acme-upstream.git' FROM workspace
            """)
      }
      for args in [["where"], ["init", "--scan", "."]] {
        let result = try SiltaBinary.run(args + ["--json"], in: scratch, cwd: repo)
        let error = try TaskStateRegressionTests.error(result)
        withKnownIssue("#260: relative origin text does not establish a shared identity") {
          #expect(error["next"] as? [String] == ["silta --ws 'acme' ws show"])
        }
      }
      let scoped = try SiltaBinary.run(
        ["--ws", "acme", "init", "--scan", "."], in: scratch, cwd: repo)
      #expect(scoped.termination == .exit(0))
    }
  }
}
