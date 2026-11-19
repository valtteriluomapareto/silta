import Foundation
import GRDB
import SiltaCore
import SiltaTestSupport
import Testing

@Suite(.blockingTestWork, .timeLimit(.minutes(1)))
struct FirstWorkspaceCommandTests {
  static let origin = "https://example.invalid/acme/platform.git"

  @Test func emptyListingPointsAtScanningTheActualClone() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "Acme Work/platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let nested = repo.appending(path: "src")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let listed = try SiltaBinary.run(["ws", "ls", "--json"], in: scratch, cwd: nested)
      #expect(listed.termination == .exit(0))
      let data = try TaskStateRegressionTests.data(listed)
      let next = data["next"] as? [String] ?? []
      withKnownIssue("#260: empty workspace listing has no scan next") {
        #expect(next.first?.hasPrefix("silta init --scan ") == true)
      }
    }
  }

  @Test func pathlessRegistrationOffersRepairBeforeCreatingAWorkspace() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "Acme Work/ac-platform")
      try InitCommandTests.makeRepo(repo, in: scratch)
      try InitCommandTests.git(["remote", "add", "origin", Self.origin], in: scratch, cwd: repo)
      let store = try TaskCommandTests.setup(scratch)
      try store.write { tx in
        try tx.database.execute(
          sql: """
            INSERT INTO repo(uid,workspace_id,slug,remote_url)
            SELECT 'acme-existing-repo',id,'declared-platform',? FROM workspace WHERE slug='acme'
            """, arguments: [Self.origin])
      }
      let whereResult = try SiltaBinary.run(["where", "--json"], in: scratch, cwd: repo)
      let collision = try SiltaBinary.run(
        ["init", "--scan", repo.path, "--json"], in: scratch)
      #expect(whereResult.termination == .exit(2))
      #expect(collision.termination == .exit(6))
      for result in [whereResult, collision] {
        let error = try TaskStateRegressionTests.error(result)
        let next = try #require((error["next"] as? [String])?.first)
        withKnownIssue("#260: missing pathless registration recovery") {
          #expect(next.hasPrefix("silta --ws 'acme' init --scan "))
        }
      }
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspace") } == 1)
      #expect(
        try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM repo_path") } == 0)
    }
  }

  @Test func missingRootNamesThePathAndRefusesTheWholeScan() throws {
    try withScratchDirectory { scratch in
      let repo = scratch.appending(path: "acme")
      let missing = scratch.appending(path: "Missing Acme")
      try InitCommandTests.makeRepo(repo, in: scratch)
      let result = try SiltaBinary.run(
        ["init", "--scan", repo.path, missing.path, "--json"], in: scratch)
      #expect(result.termination == .exit(9))
      let error = try TaskStateRegressionTests.error(result)
      withKnownIssue("#260: scan failure omits its missing root") {
        #expect((error["message"] as? String)?.contains(missing.path) == true)
      }
      #expect(
        !FileManager.default.fileExists(
          atPath: scratch.appending(path: "silta-home/silta.db").path))
    }
  }
}
